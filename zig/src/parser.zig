const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;

const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,

    const Kind = enum {
        keyword_state,
        keyword_entry,
        keyword_kernel,
        keyword_enum,
        keyword_parallel,
        keyword_on,
        keyword_always,
        keyword_var,
        keyword_context,
        keyword_extern,
        keyword_fn,
        keyword_pipeline,
        keyword_import,
        keyword_use,
        keyword_cxx,
        keyword_if,
        keyword_else,
        keyword_return,
        keyword_run,
        keyword_print,
        keyword_free,
        keyword_body,
        keyword_step,
        keyword_publish,
        keyword_enter,
        keyword_exit,
        keyword_true,
        keyword_false,
        keyword_owned,
        keyword_borrowed,
        annotation,
        ident,
        number,
        string,
        char_lit,
        arrow,
        lbrace,
        rbrace,
        lparen,
        rparen,
        lbracket,
        rbracket,
        colon,
        semicolon,
        comma,
        dot,
        plus,
        minus,
        star,
        slash,
        eq,
        eq_eq,
        lt,
        gt,
        lte,
        gte,
        not_eq,
        plus_eq,
        minus_eq,
        hash,
        newline,
        eof,
        invalid,
    };
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

        // Comments
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

        // Annotations: @ident or @ident(...)
        if (self.char == '@') {
            self.advance();
            while (isIdentChar(self.char)) self.advance();
            return self.token(.annotation);
        }

        // Identifiers and keywords
        if (isIdentStart(self.char)) {
            while (isIdentChar(self.char)) self.advance();
            const word = self.src[self.tok_start..self.pos];
            const kind = keywordMap.get(word) orelse .ident;
            return self.token(kind);
        }

        // Numbers
        if (isDigit(self.char) or (self.char == '-' and self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
            if (self.char == '-') self.advance();
            while (isDigit(self.char)) self.advance();
            if (self.char == '.') { self.advance(); while (isDigit(self.char)) self.advance(); }
            return self.token(.number);
        }

        // Hex
        if (self.char == '0' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] == 'x' or self.src[self.pos + 1] == 'X')) {
            self.advance(); self.advance();
            while (isHexDigit(self.char)) self.advance();
            return self.token(.number);
        }

        // Strings
        if (self.char == '"') {
            self.advance();
            while (self.char != '"' and self.char != '\n' and self.char != 0) {
                if (self.char == '\\') self.advance();
                self.advance();
            }
            if (self.char == '"') self.advance();
            return self.token(.string);
        }

        // Char literals
        if (self.char == '\'') {
            self.advance();
            if (self.char == '\\') self.advance();
            if (self.char != 0) self.advance();
            if (self.char == '\'') self.advance();
            return self.token(.char_lit);
        }

        // Multi-char operators
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
            return self.token(.not_eq);
        }
        if (self.char == '<' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.lte);
        }
        if (self.char == '>' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.advance(); self.advance();
            return self.token(.gte);
        }

        // Single char
        const c = self.char; self.advance();
        return switch (c) {
            '{' => self.token(.lbrace), '}' => self.token(.rbrace),
            '(' => self.token(.lparen), ')' => self.token(.rparen),
            '[' => self.token(.lbracket), ']' => self.token(.rbracket),
            ':' => self.token(.colon), ';' => self.token(.semicolon),
            ',' => self.token(.comma), '.' => self.token(.dot),
            '+' => self.token(.plus), '-' => self.token(.minus),
            '*' => self.token(.star), '/' => self.token(.slash),
            '=' => self.token(.eq), '<' => self.token(.lt), '>' => self.token(.gt),
            '#' => self.token(.hash),
            else => self.token(.invalid),
        };
    }

    fn token(self: *Lexer, kind: Token.Kind) Token {
        return .{ .kind = kind, .start = self.tok_start, .end = self.pos };
    }

    fn isIdentStart(c: u8) bool { return std.ascii.isAlphabetic(c) or c == '_'; }
    fn isIdentChar(c: u8) bool { return std.ascii.isAlphanumeric(c) or c == '_' or c == '?'; }
    fn isDigit(c: u8) bool { return std.ascii.isDigit(c); }
    fn isHexDigit(c: u8) bool { return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'); }

    const keywordMap = std.StaticStringMap(Token.Kind).initComptime(.{
        .{ "state", .keyword_state },
        .{ "entry", .keyword_entry },
        .{ "kernel", .keyword_kernel },
        .{ "enum", .keyword_enum },
        .{ "parallel", .keyword_parallel },
        .{ "on", .keyword_on },
        .{ "always", .keyword_always },
        .{ "var", .keyword_var },
        .{ "context", .keyword_context },
        .{ "extern", .keyword_extern },
        .{ "fn", .keyword_fn },
        .{ "pipeline", .keyword_pipeline },
        .{ "import", .keyword_import },
        .{ "use", .keyword_use },
        .{ "cxx", .keyword_cxx },
        .{ "if", .keyword_if },
        .{ "else", .keyword_else },
        .{ "return", .keyword_return },
        .{ "run", .keyword_run },
        .{ "print", .keyword_print },
        .{ "free", .keyword_free },
        .{ "body", .keyword_body },
        .{ "step", .keyword_step },
        .{ "publish", .keyword_publish },
        .{ "enter", .keyword_enter },
        .{ "exit", .keyword_exit },
        .{ "true", .keyword_true },
        .{ "false", .keyword_false },
        .{ "owned", .keyword_owned },
        .{ "borrowed", .keyword_borrowed },
    });
};

pub const Parser = struct {
    allocator: Allocator,
    src: []const u8,
    lexer: Lexer,
    cur_tok: Token,
    prev_tok: Token,
    nesting_depth: u32,

    pub fn init(allocator: Allocator, src: []const u8) Parser {
        var p = Parser{
            .allocator = allocator,
            .src = src,
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

    fn peek(p: *Parser, kind: Token.Kind) bool { return p.cur_tok.kind == kind; }
    fn expect(p: *Parser, kind: Token.Kind) !void {
        if (p.cur_tok.kind != kind) return error.UnexpectedToken;
        p.advance();
    }

    fn consumeNewlines(p: *Parser) void {
        while (p.peek(.newline)) p.advance();
    }

    fn identText(p: *Parser) []const u8 {
        return p.src[p.cur_tok.start..p.cur_tok.end];
    }

    pub fn parse(p: *Parser) !ast.ProgramNode {
        var program = ast.ProgramNode{
            .allocator = p.allocator,
            .states = std.ArrayList(ast.StateDefNode).init(p.allocator),
            .entries = std.ArrayList(ast.EntryDecl).init(p.allocator),
            .kernels = std.ArrayList(ast.KernelDecl).init(p.allocator),
            .enums = std.ArrayList(ast.EnumDecl).init(p.allocator),
            .parallel_blocks = std.ArrayList(ast.ParallelBlock).init(p.allocator),
            .memory = null,
            .directives = std.ArrayList([]const u8).init(p.allocator),
            .context = null,
            .extern_cpp_fns = std.ArrayList(ast.ExternCppFn).init(p.allocator),
        };

        while (p.cur_tok.kind != .eof) {
            p.consumeNewlines();

            if (p.peek(.hash)) {
                p.advance();
                const start = p.lexer.pos;
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                const dir = p.src[start..p.lexer.pos];
                try program.directives.append(std.mem.trim(u8, dir, " \t\r"));
                if (p.peek(.newline)) p.advance();
            } else if (p.peek(.keyword_state)) {
                try program.states.append(try p.parseStateDef());
            } else if (p.peek(.keyword_entry)) {
                try program.entries.append(try p.parseEntry());
            } else if (p.peek(.keyword_kernel)) {
                try program.kernels.append(try p.parseKernel());
            } else if (p.peek(.keyword_enum)) {
                try program.enums.append(try p.parseEnum());
            } else if (p.peek(.keyword_parallel)) {
                try program.parallel_blocks.append(try p.parseParallel());
            } else if (p.peek(.keyword_context)) {
                p.advance();
                _ = p.parseVariables() catch {};
            } else if (p.peek(.keyword_extern)) {
                p.advance();
                _ = p.parseString();
                try p.expect(.keyword_fn);
                const fn_name = p.identText();
                p.advance();
                try p.expect(.lparen);
                var params = std.ArrayList(ast.KernelParam).init(p.allocator);
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
                try program.extern_cpp_fns.append(.{ .name = fn_name, .parameters = params, .return_type = ret });
            } else if (p.peek(.annotation) or p.peek(.ident) or p.peek(.keyword_if) or p.peek(.keyword_return) or p.peek(.keyword_print) or p.peek(.keyword_free)) {
                // Skip stray statements at top level
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                if (p.peek(.newline)) p.advance();
            } else if (p.peek(.string) or p.peek(.number) or p.peek(.char_lit) or p.peek(.arrow) or p.peek(.minus) or p.peek(.plus) or p.peek(.star) or p.peek(.slash) or p.peek(.lparen) or p.peek(.rparen) or p.peek(.lbracket) or p.peek(.rbracket) or p.peek(.colon) or p.peek(.semicolon) or p.peek(.comma) or p.peek(.hash) or p.peek(.invalid)) {
                return error.UnexpectedToken;
            } else {
                if (p.peek(.eof)) break;
                p.advance();
            }
        }

        return program;
    }

    fn parseStateDef(p: *Parser) !ast.StateDefNode {
        try p.expect(.keyword_state);

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
        while (p.peek(.annotation)) {
            const a = p.src[p.prev_tok.start + 1 .. p.prev_tok.end];
            if (std.mem.eql(u8, a, "hot")) { hot_weight = 0.9; }
            else if (std.mem.eql(u8, a, "cold")) { hot_weight = 0.1; }
            else if (std.mem.startsWith(u8, a, "cache(")) {
                const pol = a["cache(".len..];
                cache_policy = try p.allocator.dupe(u8, std.mem.trimRight(u8, pol, ")"));
            } else if (std.mem.eql(u8, a, "fast_path")) { is_fast_path = true; }
            else if (std.mem.eql(u8, a, "always_inline")) { inline_hint = .always_inline; }
            else if (std.mem.eql(u8, a, "no_inline")) { inline_hint = .no_inline; }
            else if (std.mem.eql(u8, a, "owned")) { ownership = .owned; }
            else if (std.mem.eql(u8, a, "borrowed")) { ownership = .borrowed; }
            p.advance();
            p.consumeNewlines();
        }

        try p.expect(.lbrace);

        p.nesting_depth += 1;
        var variables = std.ArrayList(ast.VariableNode).init(p.allocator);
        var transitions = std.ArrayList(ast.TransitionNode).init(p.allocator);
        var state_enter_body: ?[]const u8 = null;
        var state_exit_body: ?[]const u8 = null;

        while (p.cur_tok.kind != .rbrace and p.cur_tok.kind != .eof) {
            p.consumeNewlines();
            if (p.peek(.rbrace)) break;

            if (p.peek(.keyword_var)) {
                const vars = try p.parseVarDecls();
                try variables.appendSlice(vars.items);
                vars.deinit();
            } else if (p.peek(.keyword_on) or p.peek(.keyword_always)) {
                try transitions.append(try p.parseTransition());
            } else if (p.peek(.keyword_enter)) {
                p.advance();
                p.consumeNewlines();
                state_enter_body = try p.parseBraceBody();
            } else if (p.peek(.keyword_exit)) {
                p.advance();
                p.consumeNewlines();
                state_exit_body = try p.parseBraceBody();
            } else if (p.peek(.annotation)) {
                p.advance();
                p.consumeNewlines();
            } else if (p.peek(.keyword_state)) {
                // Nested state - skip
                const s = try p.parseStateDef();
                s.variables.deinit();
                s.transitions.deinit();
            } else if (p.peek(.string) or p.peek(.number) or p.peek(.char_lit) or p.peek(.minus) or p.peek(.plus) or p.peek(.star) or p.peek(.slash) or p.peek(.semicolon) or p.peek(.invalid)) {
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
        try p.expect(.keyword_var);

        const is_fast_path = false;

        const name = p.identText();
        p.advance();
        try p.expect(.colon);
        const type_name = p.identText();
        p.advance();

        var default: ?[]const u8 = null;
        if (p.peek(.eq)) {
            p.advance();
            if (p.peek(.number) or p.peek(.string)) {
                default = p.src[p.cur_tok.start..p.cur_tok.end];
                p.advance();
            }
        }

        try vars.append(.{
            .name = name,
            .type_name = type_name,
            .default_value = default,
            .is_fast_path = is_fast_path,
            .cache_policy = null,
            .cache_align = null,
        });

        // Handle comma-separated
        while (p.peek(.comma)) {
            p.advance();
            const n = p.identText();
            p.advance();
            try p.expect(.colon);
            const t = p.identText();
            p.advance();
            try vars.append(.{
                .name = n,
                .type_name = t,
                .default_value = null,
                .is_fast_path = false,
                .cache_policy = null,
                .cache_align = null,
            });
        }

        if (p.peek(.newline)) p.advance();
        return vars;
    }

    fn parseTransition(p: *Parser) !ast.TransitionNode {
        var is_always = false;
        var event: ?[]const u8 = null;
        var guard: ?[]const u8 = null;
        var hot_weight: ?f64 = null;

        if (p.peek(.keyword_always)) {
            is_always = true;
            p.advance();
        } else {
            try p.expect(.keyword_on);
            event = p.identText();
            p.advance();

            // Guard [expr]
            if (p.peek(.lbracket)) {
                p.advance();
                const guardStart = p.lexer.pos;
                while (p.cur_tok.kind != .rbracket and p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                guard = std.mem.trim(u8, p.src[guardStart..p.lexer.pos], " \t");
                if (p.peek(.rbracket)) p.advance();
            }

            // Annotations
            while (p.peek(.annotation)) {
                const a = p.src[p.prev_tok.start + 1 .. p.prev_tok.end];
                if (std.mem.eql(u8, a, "hot")) { hot_weight = 0.9; }
                else if (std.mem.startsWith(u8, a, "hot(")) {
                    const valstr = a["hot(".len..std.mem.indexOfScalar(u8, a, ')') orelse a.len];
                    hot_weight = std.fmt.parseFloat(f64, valstr) catch null;
                }
                p.advance();
            }
        }

        try p.expect(.arrow);
        const target = p.identText();
        p.advance();

        if (p.peek(.newline)) p.advance();

        return ast.TransitionNode{
            .event_name = event,
            .target = target,
            .is_always = is_always,
            .hot_weight = hot_weight,
            .guard = guard,
            .body = null,
        };
    }

    fn parseEntry(p: *Parser) !ast.EntryDecl {
        try p.expect(.keyword_entry);
        const name = p.identText();
        p.advance();
        p.consumeNewlines();

        if (p.peek(.lparen)) {
            p.advance();
            if (p.peek(.rparen)) p.advance();
            p.consumeNewlines();
        }

        if (p.peek(.arrow)) {
            p.advance();
            _ = p.identText();
            p.advance();
            p.consumeNewlines();
        }

        var body_lines = std.ArrayList([]const u8).init(p.allocator);

        if (p.peek(.lbrace)) {
            p.advance();
            var depth: u32 = 1;
            while (depth > 0 and p.cur_tok.kind != .eof) {
                if (p.peek(.lbrace)) depth += 1;
                if (p.peek(.rbrace)) depth -= 1;
                if (depth > 0) {
                    // Collect body text
                    const lineStart = p.lexer.tok_start;
                    while (p.cur_tok.kind != .newline and p.cur_tok.kind != .rbrace and p.cur_tok.kind != .eof) p.advance();
                    const line = std.mem.trim(u8, p.src[lineStart..p.lexer.pos], " \t");
                    if (line.len > 0) try body_lines.append(try p.allocator.dupe(u8, line));
                    if (p.peek(.newline)) p.advance();
                }
            }
            if (p.peek(.rbrace)) p.advance();
        } else {
            while (p.cur_tok.kind != .eof and !p.peek(.keyword_state) and !p.peek(.keyword_kernel) and !p.peek(.keyword_entry) and !p.peek(.keyword_enum) and !p.peek(.keyword_parallel)) {
                const start = p.lexer.tok_start;
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .eof) p.advance();
                const line = std.mem.trim(u8, p.src[start..p.lexer.pos], " \t");
                if (line.len > 0) try body_lines.append(try p.allocator.dupe(u8, line));
                if (p.peek(.newline)) p.advance();
                p.consumeNewlines();
            }
        }

        return ast.EntryDecl{ .name = name, .body_lines = body_lines, .return_type = null };
    }

    fn parseKernel(p: *Parser) !ast.KernelDecl {
        try p.expect(.keyword_kernel);
        var annotations = std.ArrayList(ast.Annotation).init(p.allocator);
        while (p.peek(.annotation)) {
            const a = p.src[p.prev_tok.start + 1 .. p.prev_tok.end];
            try annotations.append(.{ .name = a, .value = null });
            p.advance();
        }

        const name = p.identText();
        p.advance();
        try p.expect(.lparen);
        var params = std.ArrayList(ast.KernelParam).init(p.allocator);
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

    fn parseEnum(p: *Parser) !ast.EnumDecl {
        try p.expect(.keyword_enum);
        const name = p.identText(); p.advance();
        try p.expect(.lbrace);
        var members = std.ArrayList([]const u8).init(p.allocator);
        while (!p.peek(.rbrace)) {
            const m = p.identText(); p.advance();
            try members.append(m);
            if (p.peek(.comma)) p.advance();
        }
        try p.expect(.rbrace);
        return ast.EnumDecl{ .name = name, .members = members };
    }

    fn parseParallel(p: *Parser) !ast.ParallelBlock {
        try p.expect(.keyword_parallel);
        const name = p.identText(); p.advance();
        try p.expect(.lbrace);
        var states = std.ArrayList(ast.StateDefNode).init(p.allocator);
        while (!p.peek(.rbrace)) {
            p.consumeNewlines();
            if (p.peek(.keyword_state)) {
                try states.append(try p.parseStateDef());
            } else break;
        }
        if (p.peek(.rbrace)) p.advance();
        return ast.ParallelBlock{ .name = name, .states = states };
    }

    fn parseVariables(p: *Parser) !std.ArrayList(ast.VariableNode) {
        var vars = std.ArrayList(ast.VariableNode).init(p.allocator);
        while (p.peek(.keyword_var)) {
            const v = try p.parseVarDecls();
            try vars.appendSlice(v.items);
            v.deinit();
        }
        return vars;
    }

    fn parseBraceBody(p: *Parser) !?[]const u8 {
        if (!p.peek(.lbrace)) return null;
        p.advance();
        var depth: u32 = 1;
        var buf = std.ArrayList(u8).init(p.allocator);
        defer buf.deinit();

        while (depth > 0 and p.cur_tok.kind != .eof) {
            if (p.peek(.lbrace)) depth += 1;
            if (p.peek(.rbrace)) depth -= 1;
            if (depth > 0) {
                const lineStart = p.lexer.tok_start;
                while (p.cur_tok.kind != .newline and p.cur_tok.kind != .rbrace and p.cur_tok.kind != .eof) p.advance();
                const line = std.mem.trim(u8, p.src[lineStart..p.lexer.tok_start], " \t");
                if (line.len > 0) {
                    if (buf.items.len > 0) try buf.append(';');
                    try buf.appendSlice(line);
                }
                if (p.peek(.newline)) p.advance();
            }
        }
        if (p.peek(.rbrace)) p.advance();

        if (buf.items.len == 0) return null;
        const owned = try buf.toOwnedSlice();
        return @as(?[]const u8, @as([]const u8, owned));
    }

    fn parseString(p: *Parser) ?[]const u8 {
        if (p.peek(.string)) {
            const s = p.src[p.cur_tok.start..p.cur_tok.end];
            p.advance();
            return s;
        }
        return null;
    }
};
