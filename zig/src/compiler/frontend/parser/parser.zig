const std = @import("std");
const ast = @import("ast.zig");
const gpu_ir = @import("../../gpu/gpu_ir.zig");
const Allocator = std.mem.Allocator;
const token_kind_mod = @import("../syntax/token/token_kind.zig");
const keyword_mod = @import("../syntax/token/keyword.zig");

const TokenKind = token_kind_mod.TokenKind;

const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

const Lexer = struct {
    src: []const u8,
    pos: usize,
    tok_start: usize,
    char: u8,

    fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0, .tok_start = 0, .char = if (src.len > 0) src[0] else 0 };
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
        self.char = if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn skipWs(self: *Lexer) void {
        while (self.char == ' ' or self.char == '\t' or self.char == '\r') self.advance();
    }

    fn next(self: *Lexer) Token {
        self.skipWs();
        self.tok_start = self.pos;
        if (self.char == 0) return self.token(.eof);

        if (self.char == '\n') {
            self.advance();
            return self.token(.newline);
        }

        if (self.char == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
            while (self.char != '\n' and self.char != 0) self.advance();
            self.tok_start = self.pos;
            if (self.char == '\n') { self.advance(); return self.token(.newline); }
            return self.token(.eof);
        }
        if (self.char == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
            while (self.char != '\n' and self.char != 0) self.advance();
            self.tok_start = self.pos;
            if (self.char == '\n') { self.advance(); return self.token(.newline); }
            return self.token(.eof);
        }

        if (self.char == '@') {
            self.advance();
            while (isIdentChar(self.char)) self.advance();
            return self.token(.at);
        }

        if (isIdentStart(self.char)) {
            while (isIdentChar(self.char)) self.advance();
            const word = self.src[self.tok_start..self.pos];
            return self.token(keyword_mod.lookupKeyword(word) orelse .identifier);
        }

        if (isDigit(self.char) or (self.char == '-' and self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
            if (self.char == '-') self.advance();
            while (isDigit(self.char)) self.advance();
            var is_float = false;
            if (self.char == '.') { is_float = true; self.advance(); while (isDigit(self.char)) self.advance(); }
            return self.token(if (is_float) .float_literal else .int_literal);
        }

        if (self.char == '0' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] == 'x' or self.src[self.pos + 1] == 'X')) {
            self.advance(); self.advance();
            while (isHexDigit(self.char)) self.advance();
            return self.token(.int_literal);
        }

        if (self.char == '"') {
            self.advance();
            while (self.char != '"' and self.char != '\n' and self.char != 0) {
                if (self.char == '\\') self.advance();
                self.advance();
            }
            if (self.char == '"') self.advance();
            return self.token(.string_literal);
        }

        if (self.char == '\'') {
            self.advance();
            if (self.char == '\\') self.advance();
            if (self.char != 0) self.advance();
            if (self.char == '\'') self.advance();
            return self.token(.char_literal);
        }

        if (self.char == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
            self.advance(); self.advance();
            return self.token(.arrow);
        }
        if (self.char == '+' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.plus_eq);
        }
        if (self.char == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.minus_eq);
        }
        if (self.char == '=' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.eq_eq);
        }
        if (self.char == '!' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.bang_eq);
        }
        if (self.char == '<' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.less_eq);
        }
        if (self.char == '>' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.greater_eq);
        }

        const c = self.char; self.advance();
        return switch (c) {
            '{' => self.token(.lbrace), '}' => self.token(.rbrace),
            '(' => self.token(.lparen), ')' => self.token(.rparen),
            '[' => self.token(.lbracket), ']' => self.token(.rbracket),
            ':' => self.token(.colon), ';' => self.token(.semicolon),
            ',' => self.token(.comma), '.' => self.token(.dot),
            '+' => self.token(.plus), '-' => self.token(.minus),
            '*' => self.token(.star), '/' => self.token(.slash),
            '=' => self.token(.eq), '<' => self.token(.less), '>' => self.token(.greater),
            '#' => self.token(.hash),
            else => self.token(.error_token),
        };
    }

    fn token(self: *Lexer, kind: TokenKind) Token {
        return .{ .kind = kind, .start = self.tok_start, .end = self.pos };
    }

    fn isIdentStart(c: u8) bool { return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80; }
    fn isIdentChar(c: u8) bool { return std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '<' or c == '>' or c >= 0x80; }
    fn isDigit(c: u8) bool { return std.ascii.isDigit(c); }
    fn isHexDigit(c: u8) bool { return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'); }
};

pub const Parser = struct {
    allocator: Allocator,
    src: []const u8,
    file_path: []const u8,
    lexer: Lexer,
    cur_tok: Token,
    prev_tok: Token,
    nesting_depth: u32,

    pub fn init(allocator: Allocator, src: []const u8, file_path: []const u8) Parser {
        var p = Parser{
            .allocator = allocator,
            .src = src,
            .file_path = file_path,
            .lexer = Lexer.init(src),
            .cur_tok = undefined,
            .prev_tok = undefined,
            .nesting_depth = 0,
        };
        p.advance();
        return p;
    }

    fn advance(p: *Parser) void {
        p.prev_tok = p.cur_tok;
        p.cur_tok = p.lexer.next();
    }

    fn peek(p: *Parser, kind: TokenKind) bool { return p.cur_tok.kind == kind; }
    fn expect(p: *Parser, kind: TokenKind) !void {
        if (p.cur_tok.kind != kind) {
            const found = p.src[p.cur_tok.start..p.cur_tok.end];
            std.debug.print("error: expected '{s}', got '{s}' ({s})\n", .{ @tagName(kind), std.mem.trimRight(u8, found, "\x00\x0d\x0a"), @tagName(p.cur_tok.kind) });
            return error.UnexpectedToken;
        }
        p.advance();
    }

    fn consumeNewlines(p: *Parser) void {
        while (p.peek(.newline)) p.advance();
    }

    fn isNumeric(p: *Parser) bool {
        return p.cur_tok.kind == .int_literal or p.cur_tok.kind == .float_literal;
    }

    fn identText(p: *Parser) []const u8 {
        return p.src[p.cur_tok.start..p.cur_tok.end];
    }

    fn stringText(p: *Parser) []const u8 {
        const s = p.src[p.cur_tok.start..p.cur_tok.end];
        if (s.len > 2 and s[0] == '"' and s[s.len - 1] == '"')
            return s[1 .. s.len - 1];
        return s;
    }

    fn readAnnotationFull(p: *Parser) []const u8 {
        const start = p.cur_tok.start + 1;
        var end = p.cur_tok.end;
        p.advance();
        if (p.peek(.lparen)) {
            p.advance();
            while (!p.peek(.rparen) and !p.peek(.eof) and !p.peek(.newline)) p.advance();
            end = p.cur_tok.end;
            if (p.peek(.rparen)) {
                end = p.cur_tok.end;
                p.advance();
            }
        }
        return p.src[start..end];
    }

    pub fn parse(p: *Parser) !ast.ProgramNode {
        var program = ast.ProgramNode{
            .allocator = p.allocator,
            .common = .{
                .imports = std.ArrayList(ast.ImportNode).init(p.allocator),
                .enums = std.ArrayList(ast.EnumDecl).init(p.allocator),
                .struct_defs = std.StringHashMap(ast.StructDef).init(p.allocator),
                .func_defs = std.ArrayList(ast.EntryDecl).init(p.allocator),
                .forwarders = std.ArrayList(ast.ForwardDecl).init(p.allocator),
                .extern_cpp_fns = std.ArrayList(ast.ExternCppFn).init(p.allocator),
                .directives = std.ArrayList([]const u8).init(p.allocator),
            },
            .plan = .{
                .states = std.ArrayList(ast.StateDefNode).init(p.allocator),
                .parallel_blocks = std.ArrayList(ast.ParallelBlock).init(p.allocator),
                .memory = null,
                .fire_events = std.ArrayList([]const u8).init(p.allocator),
                .initial_state = null,
            },
            .metal = .{
                .entries = std.ArrayList(ast.EntryDecl).init(p.allocator),
                .kernels = std.ArrayList(ast.KernelDecl).init(p.allocator),
                .context = null,
            },
        };
        errdefer program.deinit();

        while (p.cur_tok.kind != .eof) {
            p.consumeNewlines();

            if (p.peek(.hash)) {
                p.advance();
                const start = p.lexer.pos;
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                const dir = p.src[start..p.lexer.pos];
                try program.common.directives.append(std.mem.trim(u8, dir, " \t\r"));
                if (p.peek(.newline)) p.advance();
            } else if (p.peek(.kw_state)) {
                const s = try p.parseStateDef();
                errdefer { s.variables.deinit(); s.transitions.deinit(); }
                try program.plan.states.append(s);
            } else if (p.peek(.kw_export)) {
                p.advance();
                if (p.peek(.kw_entry)) {
                    var e = try p.parseEntry();
                    e.is_export = true;
                    errdefer e.body_lines.deinit();
                    try program.metal.entries.append(e);
                } else if (p.peek(.kw_forward)) {
                    try program.common.forwarders.append(try p.parseForward());
                } else {
                    return error.ExpectedEntryOrForwardAfterExport;
                }
            } else if (p.peek(.kw_forward)) {
                try program.common.forwarders.append(try p.parseForward());
            } else if (p.peek(.kw_entry)) {
                const e = try p.parseEntry();
                errdefer e.body_lines.deinit();
                try program.metal.entries.append(e);
            } else if (p.peek(.kw_kernel)) {
                if (p.isNewGpuKernelSyntax()) {
                    try p.skipGpuKernelBlock();
                } else {
                    const k = try p.parseKernel();
                    errdefer { k.params.deinit(); k.annotations.deinit(); }
                    try program.metal.kernels.append(k);
                }
            } else if (p.peek(.kw_struct)) {
                const s = try p.parseStructDef();
                errdefer s.fields.deinit();
                if (program.common.struct_defs.get(s.name)) |_| {
                    std.debug.print("error: duplicate struct definition '{s}'\n", .{s.name});
                    return error.DuplicateStruct;
                }
                try program.common.struct_defs.put(try p.allocator.dupe(u8, s.name), s);
            } else if (p.peek(.kw_enum)) {
                const e = try p.parseEnum();
                errdefer e.members.deinit();
                try program.common.enums.append(e);
            } else if (p.peek(.kw_parallel)) {
                const pb = try p.parseParallel();
                errdefer {
                    for (pb.states.items) |*s| { s.variables.deinit(); s.transitions.deinit(); }
                    pb.states.deinit();
                }
                try program.plan.parallel_blocks.append(pb);
            } else if (p.peek(.kw_metal)) {
                p.advance();
                try p.expect(.lbrace);
                const metal_vars = try p.parseVariables();
                p.consumeNewlines();
                try p.expect(.rbrace);
                program.metal.context = ast.ContextDecl{ .variables = metal_vars };
            } else if (p.peek(.kw_extern)) {
                p.advance();
                _ = p.parseString();
                try p.expect(.kw_fn);
                const fn_name = p.identText();
                p.advance();
                try p.expect(.lparen);
                var params = std.ArrayList(ast.KernelParam).init(p.allocator);
                errdefer params.deinit();
                while (!p.peek(.rparen)) {
                    const pname = p.identText(); p.advance();
                    try p.expect(.colon);
                    const ptype = p.identText(); p.advance();
                    try params.append(.{ .name = pname, .type_name = ptype });
                    if (p.peek(.comma)) p.advance();
                }
                try p.expect(.rparen);
                var ret: ?[]const u8 = null;
                if (p.peek(.arrow)) { p.advance(); ret = p.identText(); p.advance(); }
                try program.common.extern_cpp_fns.append(.{ .name = fn_name, .parameters = params, .return_type = ret });
                try p.expect(.semicolon);
            } else if (p.peek(.kw_import)) {
                const imp = try p.parseImport();
                try program.common.imports.append(imp);
            } else if (p.peek(.kw_fn)) {
                p.advance(); // consume 'fn'
                if (try p.tryParseFunction()) |fn_decl| {
                    try program.common.func_defs.append(fn_decl);
                } else {
                    std.debug.print("warning: fn keyword without valid function definition\n", .{});
                }
            } else if (p.peek(.identifier)) {
                // Try to parse as function definition: name(params): rettype { body }
                if (try p.tryParseFunction()) |fn_decl| {
                    try program.metal.entries.append(fn_decl);
                } else {
                    // Skip stray ident at top level
                    while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                    if (p.peek(.newline)) p.advance();
                }
            } else if (p.peek(.at) or p.peek(.kw_if) or p.peek(.kw_return) or p.peek(.kw_print) or p.peek(.kw_free)) {
                // Skip stray statements at top level
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                if (p.peek(.newline)) p.advance();
            } else if (p.peek(.kw_fire)) {
                p.advance();
                if (p.peek(.identifier)) {
                    const event_name = p.identText();
                    try program.plan.fire_events.append(try p.allocator.dupe(u8, event_name));
                    p.advance();
                }
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                if (p.peek(.newline)) p.advance();
            } else if (p.peek(.kw_machine)) {
                p.advance();
                if (p.peek(.identifier)) {
                    p.advance(); // skip machine name
                }
                p.consumeNewlines();
                if (p.peek(.lbrace)) {
                    p.advance();
                    p.nesting_depth += 1;
                    while (p.cur_tok.kind != .rbrace and p.cur_tok.kind != .eof) {
                        p.consumeNewlines();
                        if (p.peek(.rbrace)) break;
                        if (std.mem.eql(u8, p.identText(), "initial")) {
                            p.advance();
                            if (p.peek(.identifier)) {
                                program.plan.initial_state = try p.allocator.dupe(u8, p.identText());
                                p.advance();
                            }
                        } else {
                            while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                        }
                    }
                    p.nesting_depth -= 1;
                    if (p.peek(.rbrace)) p.advance();
                }
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                if (p.peek(.newline)) p.advance();
            } else if (p.peek(.string_literal) or p.isNumeric() or p.peek(.char_literal) or p.peek(.arrow) or p.peek(.minus) or p.peek(.plus) or p.peek(.star) or p.peek(.slash) or p.peek(.lparen) or p.peek(.rparen) or p.peek(.lbracket) or p.peek(.rbracket) or p.peek(.colon) or p.peek(.semicolon) or p.peek(.comma) or p.peek(.hash) or p.peek(.error_token)) {
                const found = p.src[p.cur_tok.start..p.cur_tok.end];
                std.debug.print("error: unexpected token '{s}' ({s}) at top level\n", .{ std.mem.trimRight(u8, found, "\x00\x0d\x0a"), @tagName(p.cur_tok.kind) });
                return error.UnexpectedToken;
            } else {
                if (p.peek(.eof)) break;
                p.advance();
            }
        }

        return program;
    }

    fn parseStateDef(p: *Parser) !ast.StateDefNode {
        try p.expect(.kw_state);

        const stateName = p.identText();
        p.advance();

        p.consumeNewlines();

        var base: ?[]const u8 = null;
        if (p.peek(.colon)) {
            p.advance();
            base = p.identText();
            p.advance();
            p.consumeNewlines();
        }

        var hot_weight: ?f64 = null;
        var cache_policy: ?[]const u8 = null;
        const cache_align: ?u32 = null;
        var is_fast_path = false;
        var inline_hint: ast.InlineHint = .default;
        var ownership: ast.OwnershipHint = .default;

        // Parse annotations before opening brace
        while (p.peek(.at)) {
            const full_a = p.readAnnotationFull();
            if (std.mem.eql(u8, full_a, "hot")) { hot_weight = 0.9; }
            else if (std.mem.eql(u8, full_a, "cold")) { hot_weight = 0.1; }
            else if (std.mem.startsWith(u8, full_a, "Cache(")) {
                const pol = full_a["Cache(".len..];
                cache_policy = try p.allocator.dupe(u8, std.mem.trimRight(u8, pol, ")"));
            } else if (std.mem.eql(u8, full_a, "fast_path")) { is_fast_path = true; }
            else if (std.mem.eql(u8, full_a, "always_inline")) { inline_hint = .always_inline; }
            else if (std.mem.eql(u8, full_a, "no_inline")) { inline_hint = .no_inline; }
            else if (std.mem.eql(u8, full_a, "owned")) { ownership = .owned; }
            else if (std.mem.eql(u8, full_a, "borrowed")) { ownership = .borrowed; }
            p.consumeNewlines();
        }

        try p.expect(.lbrace);

        var state_enter_body: ?[]const u8 = null;
        var state_exit_body: ?[]const u8 = null;
        p.nesting_depth += 1;
        var variables = std.ArrayList(ast.VariableNode).init(p.allocator);
        var transitions = std.ArrayList(ast.TransitionNode).init(p.allocator);
        errdefer {
            variables.deinit();
            transitions.deinit();
            if (state_enter_body) |b| p.allocator.free(b);
            if (state_exit_body) |b| p.allocator.free(b);
            if (cache_policy) |c| p.allocator.free(c);
        }

        while (p.cur_tok.kind != .rbrace and p.cur_tok.kind != .eof) {
            p.consumeNewlines();
            if (p.peek(.rbrace)) break;

            if (p.peek(.kw_var)) {
                const vars = try p.parseVarDecls();
                try variables.appendSlice(vars.items);
                vars.deinit();
            } else if (p.peek(.kw_on) or p.peek(.kw_always)) {
                try transitions.append(try p.parseTransition());
            } else if (p.peek(.kw_enter) or p.peek(.kw_entry)) {
                p.advance();
                p.consumeNewlines();
                state_enter_body = try p.parseBraceBody();
                if (state_enter_body != null) p.advance();
            } else if (p.peek(.kw_exit)) {
                p.advance();
                p.consumeNewlines();
                state_exit_body = try p.parseBraceBody();
                if (state_exit_body != null) p.advance();
            } else if (p.peek(.at)) {
                _ = p.readAnnotationFull();
                p.consumeNewlines();
            } else if (p.peek(.kw_state)) {
                // Nested state - skip
                const s = try p.parseStateDef();
                s.variables.deinit();
                s.transitions.deinit();
            } else if (p.peek(.identifier)) {
                const name = p.identText();
                p.advance();
                var var_type: []const u8 = "i64";
                if (p.peek(.colon)) {
                    p.advance();
                    var_type = p.identText();
                    p.advance();
                }
                var default: ?[]const u8 = null;
                if (p.peek(.eq)) {
                    p.advance();
                    if (p.isNumeric() or p.peek(.string_literal)) {
                        default = p.src[p.cur_tok.start..p.cur_tok.end];
                        p.advance();
                    }
                }
                try variables.append(.{
                    .name = name,
                    .type_name = var_type,
                    .default_value = default,
                    .is_fast_path = false,
                    .cache_policy = null,
                    .cache_align = null,
                });
                if (p.peek(.semicolon)) p.advance();
                while (p.peek(.comma)) {
                    p.advance();
                    p.consumeNewlines();
                    if (!p.peek(.identifier)) break;
                    const n = p.identText();
                    p.advance();
                    var t: []const u8 = "i64";
                    if (p.peek(.colon)) {
                        p.advance();
                        t = p.identText();
                        p.advance();
                    }
                    var d: ?[]const u8 = null;
                    if (p.peek(.eq)) {
                        p.advance();
                        if (p.isNumeric() or p.peek(.string_literal)) {
                            d = p.src[p.cur_tok.start..p.cur_tok.end];
                            p.advance();
                        }
                    }
                    try variables.append(.{
                        .name = n,
                        .type_name = t,
                        .default_value = d,
                        .is_fast_path = false,
                        .cache_policy = null,
                        .cache_align = null,
                    });
                }
            } else if (p.peek(.string_literal) or p.isNumeric() or p.peek(.char_literal) or p.peek(.minus) or p.peek(.plus) or p.peek(.star) or p.peek(.slash) or p.peek(.semicolon) or p.peek(.error_token)) {
                const found = p.src[p.cur_tok.start..p.cur_tok.end];
                std.debug.print("error: unexpected token '{s}' ({s}) in state body\n", .{ std.mem.trimRight(u8, found, "\x00\x0d\x0a"), @tagName(p.cur_tok.kind) });
                return error.UnexpectedToken;
            } else {
                if (p.peek(.eof)) break;
                p.advance();
            }
        }
        p.nesting_depth -= 1;

        if (p.peek(.rbrace)) p.advance();

        return ast.StateDefNode{
            .name = stateName,
            .base_class = base,
            .depth = p.nesting_depth,
            .variables = variables,
            .transitions = transitions,
            .enter_body = state_enter_body,
            .exit_body = state_exit_body,
            .hot_weight = hot_weight,
            .cache_policy = cache_policy,
            .cache_align = cache_align,
            .is_fast_path = is_fast_path,
            .inline_hint = inline_hint,
            .ownership = ownership,
        };
    }

    fn parseVarDecls(p: *Parser) !std.ArrayList(ast.VariableNode) {
        var vars = std.ArrayList(ast.VariableNode).init(p.allocator);
        
        // Support both: var x:i32 = 10 (old) and x = 10 (new auto-infer)
        const has_var_kw = p.peek(.kw_var);
        if (has_var_kw) {
            p.advance();  // consume 'var'
        }

        const is_fast_path = false;

        const name = p.identText();
        p.advance();

        // Check for type annotation (colon)
        var type_name: ?[]const u8 = null;
        if (p.peek(.colon)) {
            p.advance();  // consume ':'
            type_name = p.identText();
            p.advance();
        }

        // Expect '=' for value assignment
        var default: ?[]const u8 = null;
        if (p.peek(.eq)) {
            p.advance();
            if (p.isNumeric() or p.peek(.string_literal)) {
                default = p.src[p.cur_tok.start..p.cur_tok.end];
                p.advance();
            }
        }

        const cp = parseVarCacheAnnotation(p);
        try vars.append(.{
            .name = name,
            .type_name = type_name,  // null = auto-infer
            .default_value = default,
            .is_fast_path = is_fast_path,
            .cache_policy = cp,
            .cache_align = null,
        });

        // Handle comma-separated
        while (p.peek(.comma)) {
            p.advance();
            const n = p.identText();
            p.advance();
            
            var t: ?[]const u8 = null;
            if (p.peek(.colon)) {
                p.advance();
                t = p.identText();
                p.advance();
            }
            
            const cp2 = parseVarCacheAnnotation(p);
            try vars.append(.{
                .name = n,
                .type_name = t,  // null = auto-infer
                .default_value = null,
                .is_fast_path = false,
                .cache_policy = cp2,
                .cache_align = null,
            });
        }

        if (p.peek(.newline)) p.advance();
        if (p.peek(.semicolon)) p.advance();
        return vars;
    }

    fn parseVarCacheAnnotation(p: *Parser) ?[]const u8 {
        if (!p.peek(.at)) return null;
        const full_a = p.readAnnotationFull();
        if (std.mem.startsWith(u8, full_a, "Cache(")) {
            const pol = full_a["Cache(".len..];
            return std.mem.trimRight(u8, pol, ")");
        }
        return null;
    }

    fn parseTransition(p: *Parser) !ast.TransitionNode {
        var is_always = false;
        var event: ?[]const u8 = null;
        var guard: ?[]const u8 = null;
        var hot_weight: ?f64 = null;

        if (p.peek(.kw_always)) {
            is_always = true;
            p.advance();

            // Guard [expr] for always transitions
            if (p.peek(.lbracket)) {
                p.advance();
                const guardStart = p.cur_tok.start;
                while (p.cur_tok.kind != .rbracket and p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                guard = std.mem.trim(u8, p.src[guardStart..p.cur_tok.start], " \t");
                if (p.peek(.rbracket)) p.advance();
            }
        } else {
            try p.expect(.kw_on);
            event = p.identText();
            p.advance();

            // Guard [expr]
            if (p.peek(.lbracket)) {
                p.advance();
                const guardStart = p.cur_tok.start;
                while (p.cur_tok.kind != .rbracket and p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                guard = std.mem.trim(u8, p.src[guardStart..p.cur_tok.start], " \t");
                if (p.peek(.rbracket)) p.advance();
            }

            // Annotations
            while (p.peek(.at)) {
                const full_a = p.readAnnotationFull();
                if (std.mem.eql(u8, full_a, "hot")) { hot_weight = 0.9; }
                else if (std.mem.startsWith(u8, full_a, "hot(")) {
                    const valstr = full_a["hot(".len..std.mem.indexOfScalar(u8, full_a, ')') orelse full_a.len];
                    hot_weight = std.fmt.parseFloat(f64, valstr) catch null;
                }
                p.advance();
            }
        }

        try p.expect(.arrow);
        const target = p.identText();
        p.advance();

        if (p.peek(.newline)) p.advance();
        if (p.peek(.semicolon)) p.advance();

        return ast.TransitionNode{
            .event_name = event,
            .target = target,
            .is_always = is_always,
            .hot_weight = hot_weight,
            .guard = guard,
            .body = null,
        };
    }

    fn tryParseFunction(p: *Parser) !?ast.EntryDecl {
        // Check for pattern: name (...) : type { body }
        // Save position in case it's not a function
        const save_pos = p.lexer.pos;
        const save_char = p.lexer.char;
        const save_tok = p.cur_tok;

        const name = p.identText();
        p.advance();
        p.consumeNewlines();

        if (!p.peek(.lparen)) {
            p.lexer.pos = save_pos;
            p.lexer.char = save_char;
            p.cur_tok = save_tok;
            return null;
        }
        p.advance(); // (

        var params = std.ArrayList(ast.KernelParam).init(p.allocator);
        errdefer params.deinit();
        while (!p.peek(.rparen) and !p.peek(.eof)) {
            const pname = p.identText();
            p.advance();
            if (p.peek(.colon)) {
                p.advance();
                const ptype = p.identText();
                p.advance();
                try params.append(.{ .name = pname, .type_name = ptype });
            } else {
                try params.append(.{ .name = pname, .type_name = "int" });
            }
            if (p.peek(.comma)) p.advance();
        }
        if (!p.peek(.rparen)) {
            params.deinit();
            p.lexer.pos = save_pos;
            p.lexer.char = save_char;
            p.cur_tok = save_tok;
            return null;
        }
        p.advance(); // )
        p.consumeNewlines();

        var ret_type: ?[]const u8 = null;
        if (p.peek(.arrow) or p.peek(.colon)) {
            p.advance();
            ret_type = p.identText();
            p.advance();
            p.consumeNewlines();
        }

        // Now check for { body } — if not, restore and return null
        if (!p.peek(.lbrace)) {
            params.deinit();
            p.lexer.pos = save_pos;
            p.lexer.char = save_char;
            p.cur_tok = save_tok;
            return null;
        }
        if (p.peek(.arrow)) {
            p.advance();
            ret_type = p.identText();
            p.advance();
            p.consumeNewlines();
        }

        if (!p.peek(.lbrace)) {
            params.deinit();
            p.lexer.pos = save_pos;
            p.lexer.char = save_char;
            p.cur_tok = save_tok;
            return null;
        }

        const lbrace_start = p.cur_tok.start;
        p.advance();
        var depth: u32 = 1;
        var scan_pos = lbrace_start + 1;
        while (scan_pos < p.src.len and depth > 0) {
            if (p.src[scan_pos] == '"') {
                scan_pos += 1;
                while (scan_pos < p.src.len and p.src[scan_pos] != '"') {
                    if (p.src[scan_pos] == '\\') scan_pos += 1;
                    scan_pos += 1;
                }
            }
            if (scan_pos >= p.src.len) break;
            if (p.src[scan_pos] == '{') depth += 1;
            if (p.src[scan_pos] == '}') depth -= 1;
            scan_pos += 1;
        }
        var body_lines = std.ArrayList([]const u8).init(p.allocator);
        errdefer body_lines.deinit();
        if (scan_pos > lbrace_start + 1) {
            const body_text = p.src[lbrace_start + 1 .. scan_pos - 1];
            var lines_iter = std.mem.splitScalar(u8, body_text, '\n');
            while (lines_iter.next()) |raw_line| {
                const t = std.mem.trim(u8, raw_line, " \t\r");
                if (t.len > 0) try body_lines.append(try p.allocator.dupe(u8, t));
            }
        }
        p.lexer.pos = scan_pos - 1;
        p.lexer.char = if (scan_pos - 1 < p.src.len) p.src[scan_pos - 1] else 0;
        p.cur_tok = p.lexer.next();

        return ast.EntryDecl{
            .name = try p.allocator.dupe(u8, name),
            .params = params,
            .body_lines = body_lines,
            .return_type = ret_type,
            .is_export = false,
        };
    }

    fn parseEntry(p: *Parser) !ast.EntryDecl {
        try p.expect(.kw_entry);

        const is_unnamed = p.peek(.lbrace);
        const name = if (is_unnamed) "" else p.identText();
        if (!is_unnamed) p.advance();
        p.consumeNewlines();

        var params = std.ArrayList(ast.KernelParam).init(p.allocator);
        if (p.peek(.lparen)) {
            p.advance();
            while (!p.peek(.rparen) and !p.peek(.eof)) {
                const pname = p.identText();
                p.advance();
                try p.expect(.colon);
                var ptype_buf: []const u8 = "";
                if (p.peek(.star)) {
                    ptype_buf = "*";
                    p.advance();
                }
                const ptype_start = p.identText();
                p.advance();
                ptype_buf = if (ptype_buf.len > 0) try std.mem.concat(p.allocator, u8, &.{ ptype_buf, ptype_start }) else ptype_start;
                try params.append(.{ .name = pname, .type_name = ptype_buf });
                if (p.peek(.comma)) p.advance();
            }
            if (p.peek(.rparen)) p.advance();
            p.consumeNewlines();
        }

        var entry_ret_type: ?[]const u8 = null;
        if (p.peek(.arrow) or p.peek(.colon)) {
            p.advance();
            entry_ret_type = p.identText();
            p.advance();
            p.consumeNewlines();
        }

        var body_lines = std.ArrayList([]const u8).init(p.allocator);
        errdefer body_lines.deinit();

        if (p.peek(.lbrace)) {
            const lbrace_start = p.cur_tok.start;
            p.advance();
            var depth: u32 = 1;
            var scan_pos = lbrace_start + 1;
            while (scan_pos < p.src.len and depth > 0) {
                if (p.src[scan_pos] == '"') {
                    scan_pos += 1;
                    while (scan_pos < p.src.len and p.src[scan_pos] != '"') {
                        if (p.src[scan_pos] == '\\') scan_pos += 1;
                        scan_pos += 1;
                    }
                }
                if (scan_pos >= p.src.len) break;
                if (p.src[scan_pos] == '{') depth += 1;
                if (p.src[scan_pos] == '}') depth -= 1;
                scan_pos += 1;
            }
            if (scan_pos > lbrace_start + 1) {
                const body_text = p.src[lbrace_start + 1 .. scan_pos - 1];
                var lines_iter = std.mem.splitScalar(u8, body_text, '\n');
                while (lines_iter.next()) |raw_line| {
                    const t = std.mem.trim(u8, raw_line, " \t\r");
                    if (t.len > 0) try body_lines.append(try p.allocator.dupe(u8, t));
                }
            }
            // Re-sync lexer to position after the matching }
            p.lexer.pos = scan_pos - 1;
            p.lexer.char = if (scan_pos - 1 < p.src.len) p.src[scan_pos - 1] else 0;
            p.cur_tok = p.lexer.next();
        } else {
            while (p.cur_tok.kind != .eof and !p.peek(.kw_state) and !p.peek(.kw_kernel) and !p.peek(.kw_entry) and !p.peek(.kw_enum) and !p.peek(.kw_parallel) and !p.peek(.kw_export) and !p.peek(.kw_forward)) {
                const start = p.lexer.tok_start;
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                const line = std.mem.trim(u8, p.src[start..p.lexer.pos], " \t");
                if (line.len > 0) try body_lines.append(try p.allocator.dupe(u8, line));
                if (p.peek(.newline)) p.advance();
                p.consumeNewlines();
            }
        }

        return ast.EntryDecl{ .name = name, .params = params, .body_lines = body_lines, .return_type = entry_ret_type, .is_export = false };
    }

    fn parseForward(p: *Parser) !ast.ForwardDecl {
        try p.expect(.kw_forward);
        const name = p.identText();
        p.advance();
        p.consumeNewlines();
        try p.expect(.eq);
        const dll = p.stringText();
        p.advance();
        if (p.peek(.semicolon)) p.advance();
        p.consumeNewlines();
        return ast.ForwardDecl{ .export_name = name, .target_dll = dll };
    }

    fn parseKernel(p: *Parser) !ast.KernelDecl {
        try p.expect(.kw_kernel);
        var annotations = std.ArrayList(ast.Annotation).init(p.allocator);
        errdefer annotations.deinit();
        while (p.peek(.at)) {
            const full_a = p.readAnnotationFull();
            try annotations.append(.{ .name = full_a, .value = null });
        }

        const name = p.identText();
        p.advance();
        try p.expect(.lparen);
        var params = std.ArrayList(ast.KernelParam).init(p.allocator);
        errdefer params.deinit();
        while (!p.peek(.rparen)) {
            const pn = p.identText(); p.advance();
            try p.expect(.colon);
            const pt = p.identText(); p.advance();
            try params.append(.{ .name = pn, .type_name = pt });
            if (p.peek(.comma)) p.advance();
        }
        try p.expect(.rparen);
        var ret: ?[]const u8 = null;
        if (p.peek(.arrow)) { p.advance(); ret = p.identText(); p.advance(); }
        return ast.KernelDecl{ .name = name, .params = params, .return_type = ret, .annotations = annotations };
    }

    fn isNewGpuKernelSyntax(p: *Parser) bool {
        var pos = p.cur_tok.end;
        while (pos < p.src.len and (p.src[pos] == ' ' or p.src[pos] == '\t' or p.src[pos] == '\n' or p.src[pos] == '\r')) pos += 1;
        while (pos < p.src.len and (std.ascii.isAlphanumeric(p.src[pos]) or p.src[pos] == '_')) pos += 1;
        while (pos < p.src.len and (p.src[pos] == ' ' or p.src[pos] == '\t' or p.src[pos] == '\n' or p.src[pos] == '\r')) pos += 1;
        return pos < p.src.len and p.src[pos] == '{';
    }

    fn skipGpuKernelBlock(p: *Parser) !void {
        p.advance(); // skip 'kernel' keyword
        p.advance(); // skip kernel name
        p.consumeNewlines();
        try p.expect(.lbrace);
        var depth: u32 = 1;
        while (depth > 0) {
            p.advance();
            if (p.peek(.lbrace)) depth += 1;
            if (p.peek(.rbrace)) depth -= 1;
            if (p.peek(.eof)) break;
        }
    }

    pub fn parseGpuKernelBlock(p: *Parser) !gpu_ir.GpuKernel {
        try p.expect(.kw_kernel);
        const kname = try p.allocator.dupe(u8, p.identText());
        p.advance();
        p.consumeNewlines();
        try p.expect(.lbrace);

        var resources = std.ArrayList(gpu_ir.ResourceDecl).init(p.allocator);
        errdefer resources.deinit();
        var cbuffer_members = std.ArrayList(gpu_ir.CbufferMember).init(p.allocator);
        errdefer cbuffer_members.deinit();
        var entries = std.ArrayList(gpu_ir.EntryDecl).init(p.allocator);
        var globals_lines = std.ArrayList([]const u8).init(p.allocator);
        errdefer globals_lines.deinit();

        var nt_x: u32 = 8;
        var nt_y: u32 = 8;
        var nt_z: u32 = 1;

        while (!p.peek(.rbrace) and !p.peek(.eof)) {
            p.consumeNewlines();
            if (p.peek(.rbrace)) break;

            // @numthreads(x,y,z)
            if (p.peek(.at)) {
                const ann_full = p.readAnnotationFull();
                if (std.mem.startsWith(u8, ann_full, "numthreads(")) {
                    const nrest = ann_full["numthreads(".len..ann_full.len -| 1];
                    var it = std.mem.splitScalar(u8, nrest, ',');
                    if (it.next()) |xs| nt_x = std.fmt.parseInt(u32, std.mem.trim(u8, xs, " \t"), 10) catch 8;
                    if (it.next()) |ys| nt_y = std.fmt.parseInt(u32, std.mem.trim(u8, ys, " \t"), 10) catch 8;
                    if (it.next()) |zs| nt_z = std.fmt.parseInt(u32, std.mem.trim(u8, zs, " \t"), 10) catch 1;
                }
                continue;
            }

            // entry main(x:u32,y:u32) { ... }
            if (p.peek(.kw_entry)) {
                p.advance();
                const ename = try p.allocator.dupe(u8, p.identText());
                p.advance();
                try p.expect(.lparen);
                const xp = try p.allocator.dupe(u8, p.identText());
                p.advance();
                try p.expect(.colon);
                _ = p.identText(); p.advance(); // type
                try p.expect(.comma);
                const yp = try p.allocator.dupe(u8, p.identText());
                p.advance();
                try p.expect(.colon);
                _ = p.identText(); p.advance(); // type
                try p.expect(.rparen);
                p.consumeNewlines();
                try p.expect(.lbrace);

                var body = std.ArrayList([]const u8).init(p.allocator);
                const brace_start = p.prev_tok.start;
                var depth: u32 = 1;
                var scan_pos = brace_start + 1;
                while (scan_pos < p.src.len and depth > 0) {
                    if (p.src[scan_pos] == '"') {
                        scan_pos += 1;
                        while (scan_pos < p.src.len and p.src[scan_pos] != '"') {
                            if (p.src[scan_pos] == '\\') scan_pos += 1;
                            scan_pos += 1;
                        }
                    }
                    if (scan_pos >= p.src.len) break;
                    if (p.src[scan_pos] == '{') depth += 1;
                    if (p.src[scan_pos] == '}') depth -= 1;
                    if (depth > 0) scan_pos += 1;
                }

                if (scan_pos > brace_start + 1) {
                    const body_text = p.src[brace_start + 1 .. scan_pos];
                    var lines_iter = std.mem.splitScalar(u8, body_text, '\n');
                    while (lines_iter.next()) |raw_line| {
                        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                        if (trimmed.len > 0) try body.append(try p.allocator.dupe(u8, trimmed));
                    }
                }

                // Sync lexer to after }
                p.lexer.pos = scan_pos + 1;
                p.lexer.char = if (scan_pos + 1 < p.src.len) p.src[scan_pos + 1] else 0;
                p.cur_tok = p.lexer.next();

                try entries.append(gpu_ir.EntryDecl{
                    .name = ename, .x_param = xp, .y_param = yp,
                    .body_lines = body,
                    .numthreads = .{ .x = nt_x, .y = nt_y, .z = nt_z },
                });
                continue;
            }

            // globals { ... }
            if (std.mem.eql(u8, p.identText(), "globals")) {
                p.advance();
                p.consumeNewlines();
                try p.expect(.lbrace);
                const brace_start = p.prev_tok.start;
                var scan_pos = brace_start + 1;
                var depth: u32 = 1;
                while (scan_pos < p.src.len and depth > 0) {
                    if (p.src[scan_pos] == '"') {
                        scan_pos += 1;
                        while (scan_pos < p.src.len and p.src[scan_pos] != '"') {
                            if (p.src[scan_pos] == '\\') scan_pos += 1;
                            scan_pos += 1;
                        }
                    }
                    if (scan_pos >= p.src.len) break;
                    if (p.src[scan_pos] == '{') depth += 1;
                    if (p.src[scan_pos] == '}') depth -= 1;
                    if (depth > 0) scan_pos += 1;
                }
                if (scan_pos > brace_start + 1) {
                    const body_text = p.src[brace_start + 1 .. scan_pos];
                    var lines_iter = std.mem.splitScalar(u8, body_text, '\n');
                    while (lines_iter.next()) |raw_line| {
                        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                        if (trimmed.len > 0) try globals_lines.append(try p.allocator.dupe(u8, trimmed));
                    }
                }
                p.lexer.pos = scan_pos + 1;
                p.lexer.char = if (scan_pos + 1 < p.src.len) p.src[scan_pos + 1] else 0;
                p.cur_tok = p.lexer.next();
                continue;
            }

            // Variable declaration: name : Type @annotation
            const vname = try p.allocator.dupe(u8, p.identText());
            p.advance();
            try p.expect(.colon);
            const type_text = p.identText();
            p.advance();

            if (p.peek(.at)) {
                const ann = p.readAnnotationFull();
                if (std.mem.startsWith(u8, ann, "binding(")) {
                    const reg_str = ann["binding(".len .. ann.len -| 1];
                    const gpu_type = try gpuParseType(type_text);
                    const reg = gpuParseBindingReg(reg_str);
                    try resources.append(.{ .name = vname, .gpu_type = gpu_type, .binding = .{ .reg = reg } });
                } else if (std.mem.startsWith(u8, ann, "cbuffer(")) {
                    const reg_str = ann["cbuffer(".len .. ann.len -| 1];
                    const reg = std.fmt.parseInt(u32, std.mem.trim(u8, reg_str, " \t"), 10) catch 0;
                    const ct = gpuParseCbufferType(type_text);
                    try cbuffer_members.append(.{ .name = vname, .scalar_type = ct.scalar, .vector_width = ct.width, .slot = .{ .reg = reg } });
                }
            }
        }

        try p.expect(.rbrace);

        return gpu_ir.GpuKernel{ .name = kname, .resources = resources, .cbuffer_members = cbuffer_members, .entries = entries, .globals_lines = globals_lines };
    }

    fn parseStructDef(p: *Parser) !ast.StructDef {
        try p.expect(.kw_struct);
        const name = p.identText(); p.advance();
        p.consumeNewlines();
        try p.expect(.lbrace);
        var fields = std.ArrayList(ast.StructField).init(p.allocator);
        errdefer fields.deinit();
        while (!p.peek(.rbrace)) {
            p.consumeNewlines();
            if (p.peek(.rbrace)) break;
            const fname = p.identText(); p.advance();
            try p.expect(.colon);
            const ftype = p.identText(); p.advance();
            try fields.append(.{ .name = fname, .type_name = ftype });
            if (p.peek(.comma)) p.advance();
        }
        try p.expect(.rbrace);
        return ast.StructDef{ .name = name, .fields = fields };
    }

    fn parseEnum(p: *Parser) !ast.EnumDecl {
        try p.expect(.kw_enum);
        const name = p.identText(); p.advance();
        try p.expect(.lbrace);
        var members = std.ArrayList([]const u8).init(p.allocator);
        errdefer members.deinit();
        while (!p.peek(.rbrace)) {
            const m = p.identText(); p.advance();
            try members.append(m);
            if (p.peek(.comma)) p.advance();
        }
        try p.expect(.rbrace);
        return ast.EnumDecl{ .name = name, .members = members };
    }

    fn parseParallel(p: *Parser) !ast.ParallelBlock {
        try p.expect(.kw_parallel);
        const name = p.identText(); p.advance();
        try p.expect(.lbrace);
        var states = std.ArrayList(ast.StateDefNode).init(p.allocator);
        errdefer {
            for (states.items) |*s| { s.variables.deinit(); s.transitions.deinit(); }
            states.deinit();
        }
        while (!p.peek(.rbrace)) {
            p.consumeNewlines();
            if (p.peek(.kw_state)) {
                try states.append(try p.parseStateDef());
            } else break;
        }
        if (p.peek(.rbrace)) p.advance();
        return ast.ParallelBlock{ .name = name, .states = states };
    }

    fn parseVariables(p: *Parser) !std.ArrayList(ast.VariableNode) {
        var vars = std.ArrayList(ast.VariableNode).init(p.allocator);
        errdefer vars.deinit();
        p.consumeNewlines();
        while (p.peek(.kw_var)) {
            const v = try p.parseVarDecls();
            try vars.appendSlice(v.items);
            v.deinit();
            p.consumeNewlines();
        }
        return vars;
    }

    fn parseBraceBody(p: *Parser) !?[]const u8 {
        if (!p.peek(.lbrace)) return null;
        const lbrace_start = p.cur_tok.start;
        p.advance();
        var depth: u32 = 1;
        var scan_pos = lbrace_start + 1;
        while (scan_pos < p.src.len and depth > 0) {
            if (p.src[scan_pos] == '"') {
                scan_pos += 1;
                while (scan_pos < p.src.len and p.src[scan_pos] != '"') {
                    if (p.src[scan_pos] == '\\') scan_pos += 1;
                    scan_pos += 1;
                }
            }
            if (scan_pos >= p.src.len) break;
            if (p.src[scan_pos] == '{') depth += 1;
            if (p.src[scan_pos] == '}') depth -= 1;
            scan_pos += 1;
        }
        var buf = std.ArrayList(u8).init(p.allocator);
        defer buf.deinit();
        if (scan_pos > lbrace_start + 1) {
            const body_text = p.src[lbrace_start + 1 .. scan_pos - 1];
            var lines_iter = std.mem.splitScalar(u8, body_text, '\n');
            while (lines_iter.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len > 0) {
                    if (buf.items.len > 0) try buf.append(';');
                    try buf.appendSlice(line);
                }
            }
        }
        p.lexer.pos = scan_pos - 1;
        p.lexer.char = if (scan_pos - 1 < p.src.len) p.src[scan_pos - 1] else 0;
        p.cur_tok = p.lexer.next();
        if (buf.items.len == 0) return null;
        const owned = try buf.toOwnedSlice();
        return @as(?[]const u8, @as([]const u8, owned));
    }

    fn parseStringLiteral(p: *Parser) ![]const u8 {
        const s = p.src[p.cur_tok.start..p.cur_tok.end];
        p.advance();
        if (s.len > 2 and s[0] == '"' and s[s.len - 1] == '"')
            return s[1 .. s.len - 1];
        return s;
    }

    fn parseImport(p: *Parser) !ast.ImportNode {
        try p.expect(.kw_import);
        const path = try p.parseStringLiteral();
        if (p.peek(.semicolon)) p.advance();
        return ast.ImportNode{ .path = try p.allocator.dupe(u8, path) };
    }

    fn parseString(p: *Parser) ?[]const u8 {
        if (p.peek(.string_literal)) {
            const s = p.src[p.cur_tok.start..p.cur_tok.end];
            p.advance();
            return s;
        }
        return null;
    }
};

fn gpuParseFormatWidth(inner: []const u8) struct { format: gpu_ir.ScalarType, width: gpu_ir.VectorWidth } {
    const format = gpuParseScalarType(inner);
    var width: gpu_ir.VectorWidth = .one;
    if (std.mem.endsWith(u8, inner, "2")) width = .two;
    if (std.mem.endsWith(u8, inner, "3")) width = .three;
    if (std.mem.endsWith(u8, inner, "4")) width = .four;
    return .{ .format = format, .width = width };
}

// GPU type helpers (file scope)
fn gpuParseType(type_str: []const u8) !gpu_ir.GpuType {
    if (std.mem.startsWith(u8, type_str, "Texture2D<")) {
        const inner = type_str["Texture2D<".len .. type_str.len - 1];
        const fw = gpuParseFormatWidth(inner);
        return .{ .kind = .{ .resource_typed = .{ .kind = .texture2d, .format = fw.format, .width = fw.width } } };
    }
    if (std.mem.startsWith(u8, type_str, "RWTexture2D<")) {
        const inner = type_str["RWTexture2D<".len .. type_str.len - 1];
        const fw = gpuParseFormatWidth(inner);
        return .{ .kind = .{ .resource_typed = .{ .kind = .rw_texture2d, .format = fw.format, .width = fw.width } } };
    }
    if (std.mem.eql(u8, type_str, "SamplerState")) {
        return .{ .kind = .{ .resource = .sampler_state } };
    }
    return gpu_ir.GpuType{ .kind = .{ .resource = .texture2d } };
}

fn gpuParseBindingReg(s: []const u8) u32 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return 0;
    if (std.ascii.isDigit(trimmed[0])) return std.fmt.parseInt(u32, trimmed, 10) catch 0;
    if (trimmed.len >= 2) return std.fmt.parseInt(u32, trimmed[1..], 10) catch 0;
    return 0;
}

fn gpuParseCbufferType(s: []const u8) struct { scalar: gpu_ir.ScalarType, width: gpu_ir.VectorWidth } {
    const scalar = gpuParseScalarType(s);
    var width: gpu_ir.VectorWidth = .one;
    if (std.mem.endsWith(u8, s, "2")) width = .two;
    if (std.mem.endsWith(u8, s, "3")) width = .three;
    if (std.mem.endsWith(u8, s, "4")) width = .four;
    return .{ .scalar = scalar, .width = width };
}

fn gpuParseScalarType(s: []const u8) gpu_ir.ScalarType {
    if (std.mem.eql(u8, s, "float4") or std.mem.eql(u8, s, "float") or std.mem.eql(u8, s, "float3") or std.mem.eql(u8, s, "float2") or std.mem.eql(u8, s, "f32")) return .f32;
    if (std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "i32") or std.mem.eql(u8, s, "int2") or std.mem.eql(u8, s, "int3") or std.mem.eql(u8, s, "int4")) return .i32;
    if (std.mem.eql(u8, s, "uint") or std.mem.eql(u8, s, "u32") or std.mem.eql(u8, s, "uint2") or std.mem.eql(u8, s, "uint3") or std.mem.eql(u8, s, "uint4")) return .u32;
    if (std.mem.eql(u8, s, "half") or std.mem.eql(u8, s, "f16")) return .f16;
    return .f32;
}
