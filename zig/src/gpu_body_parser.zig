const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ir = @import("gpu_ir.zig");

pub const ParserError = error{
    UnexpectedToken,
    UnknownType,
    UnknownIdentifier,
    ExpectedSemicolon,
    ExpectedExpression,
    ExpectedIdentifier,
    ExpectedType,
    ExpectedLparen,
    ExpectedRparen,
    ExpectedLbrace,
    ExpectedRbrace,
    ExpectedLbracket,
    ExpectedRbracket,
    UnterminatedBlock,
    InvalidNumber,
    InvalidAssignment,
    TooManyErrors,
    Overflow,
    InvalidCharacter,
} || Allocator.Error;

const TokenKind = enum {
    int_literal,
    float_literal,
    identifier,
    type_name,
    kw_if,
    kw_else,
    kw_for,
    kw_while,
    kw_return,
    kw_true,
    kw_false,
    kw_void,
    kw_unroll,
    kw_branch,
    kw_flatten,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    semicolon,
    comma,
    dot,
    plus,
    minus,
    star,
    slash,
    percent,
    percenteq,
    assign,
    pluseq,
    minuseq,
    stareq,
    slasheq,
    plusplus,
    minusminus,
    eqeq,
    neq,
    lt,
    gt,
    lte,
    gte,
    andand,
    oror,
    bang,
    question,
    colon,
    eof,
};

const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

const PhiIncoming = gpu_ir.PhiIncoming;

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

fn lookupKeyword(name: []const u8) ?TokenKind {
    const keywords = std.StaticStringMap(TokenKind).initComptime(.{
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "for", .kw_for },
        .{ "while", .kw_while },
        .{ "return", .kw_return },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "void", .kw_void },
        .{ "unroll", .kw_unroll },
        .{ "branch", .kw_branch },
        .{ "flatten", .kw_flatten },
    });
    return keywords.get(name);
}

fn lookupTypeName(name: []const u8) ?gpu_ir.TypeRef {
    const types = std.StaticStringMap(gpu_ir.TypeRef).initComptime(.{
        .{ "float", .f32 },
        .{ "float2", .vec2f },
        .{ "float3", .vec3f },
        .{ "float4", .vec4f },
        .{ "int", .i32 },
        .{ "int2", .vec2i },
        .{ "int3", .vec3i },
        .{ "int4", .vec4i },
        .{ "uint", .u32 },
        .{ "uint2", .vec2u },
        .{ "uint3", .vec3u },
        .{ "uint4", .vec4u },
        .{ "half", .f16 },
        .{ "bool", .u32 },
        .{ "float4x4", .mat4x4f },
    });
    return types.get(name);
}

fn tokenize(allocator: Allocator, source: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];

        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }

        if (c == '/' and i + 1 < source.len) {
            if (source[i + 1] == '/') {
                i += 2;
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                if (i + 1 < source.len) i += 2;
                continue;
            }
        }

        if (isAlpha(c)) {
            const start = i;
            while (i < source.len and isAlphaNum(source[i])) i += 1;
            const word = source[start..i];
            if (lookupKeyword(word)) |kw| {
                try tokens.append(.{ .kind = kw, .start = start, .end = i });
            } else if (lookupTypeName(word) != null) {
                try tokens.append(.{ .kind = .type_name, .start = start, .end = i });
            } else {
                try tokens.append(.{ .kind = .identifier, .start = start, .end = i });
            }
            continue;
        }

        if (isDigit(c)) {
            const start = i;
            var is_float = false;
            while (i < source.len and (isDigit(source[i]) or source[i] == '.')) {
                if (source[i] == '.') is_float = true;
                i += 1;
            }
            if (!is_float and i < source.len and source[i] == 'u') {
                i += 1;
            }
            if (i < source.len and (source[i] == 'e' or source[i] == 'E')) {
                is_float = true;
                i += 1;
                if (i < source.len and (source[i] == '+' or source[i] == '-')) i += 1;
                while (i < source.len and isDigit(source[i])) i += 1;
            }
            try tokens.append(.{
                .kind = if (is_float) .float_literal else .int_literal,
                .start = start,
                .end = i,
            });
            continue;
        }

        if (c == '"') {
            i += 1;
            while (i < source.len and source[i] != '"') {
                if (source[i] == '\\') i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }

        const start = i;
        i += 1;

        const kind: TokenKind = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ';' => .semicolon,
            ',' => .comma,
            '.' => .dot,
            '+' => if (i < source.len and source[i] == '+') blk: {
                i += 1;
                break :blk .plusplus;
            } else if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .pluseq;
            } else .plus,
            '-' => if (i < source.len and source[i] == '-') blk: {
                i += 1;
                break :blk .minusminus;
            } else if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .minuseq;
            } else .minus,
            '*' => if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .stareq;
            } else .star,
            '/' => if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .slasheq;
            } else .slash,
            '%' => if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .percenteq;
            } else .percent,
            '=' => if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .eqeq;
            } else .assign,
            '!' => if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .neq;
            } else .bang,
            '<' => if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .lte;
            } else .lt,
            '>' => if (i < source.len and source[i] == '=') blk: {
                i += 1;
                break :blk .gte;
            } else .gt,
            '&' => if (i < source.len and source[i] == '&') blk: {
                i += 1;
                break :blk .andand;
            } else return error.UnexpectedToken,
            '|' => if (i < source.len and source[i] == '|') blk: {
                i += 1;
                break :blk .oror;
            } else return error.UnexpectedToken,
            '?' => .question,
            ':' => .colon,
            else => return error.UnexpectedToken,
        };

        try tokens.append(.{ .kind = kind, .start = start, .end = i });
    }

    try tokens.append(.{ .kind = .eof, .start = source.len, .end = source.len });
    return tokens.toOwnedSlice();
}

fn typeRefFromName(name: []const u8) ?gpu_ir.TypeRef {
    return lookupTypeName(name);
}

const VarEntry = struct {
    value_id: gpu_ir.ValueId,
    type_ref: gpu_ir.TypeRef,
    is_array: bool,
    array_dims: []const u32,
};

fn cloneVarMap(allocator: Allocator, src: *const std.StringHashMap(VarEntry)) !std.StringHashMap(VarEntry) {
    var map = std.StringHashMap(VarEntry).init(allocator);
    var it = src.iterator();
    while (it.next()) |entry| {
        try map.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return map;
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: []const Token,
    pos: usize,

    blocks: std.ArrayList(gpu_ir.IrBasicBlock),
    next_block_id: gpu_ir.BlockId,
    next_value_id: gpu_ir.ValueId,
    cur_block_idx: usize,

    var_map: std.StringHashMap(VarEntry),
    resources: []const gpu_ir.IrResourceDecl,
    cbuffer: []const gpu_ir.IrCbufferMember,
    locals: std.ArrayList(gpu_ir.LocalDecl),
    type_map: std.AutoHashMapUnmanaged(gpu_ir.ValueId, gpu_ir.TypeRef),
    resource_format_map: std.AutoHashMapUnmanaged(gpu_ir.ValueId, gpu_ir.TypeRef),
    func_types: std.StringHashMap(gpu_ir.TypeRef),

    fn init(allocator: Allocator, source: []const u8, tokens: []const Token, resources: []const gpu_ir.IrResourceDecl, cbuffer: []const gpu_ir.IrCbufferMember, func_types: std.StringHashMap(gpu_ir.TypeRef)) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .tokens = tokens,
            .pos = 0,
            .blocks = std.ArrayList(gpu_ir.IrBasicBlock).init(allocator),
            .next_block_id = 0,
            .next_value_id = 0,
            .cur_block_idx = 0,
            .var_map = std.StringHashMap(VarEntry).init(allocator),
            .resources = resources,
            .cbuffer = cbuffer,
            .locals = std.ArrayList(gpu_ir.LocalDecl).init(allocator),
            .type_map = .{},
            .resource_format_map = .{},
            .func_types = func_types,
        };
    }

    fn deinit(self: *Parser) void {
        for (self.blocks.items) |*b| {
            for (b.instrs.items) |*inst| {
                if (inst.operands.len > 0) self.allocator.free(inst.operands);
                if (inst.data == .phi_incoming) self.allocator.free(inst.data.phi_incoming);
                if (inst.data == .call_info) {
                    self.allocator.free(inst.data.call_info.args);
                    self.allocator.free(inst.data.call_info.callee);
                }
                if (inst.data == .string and inst.data.string.len > 0) self.allocator.free(inst.data.string);
            }
            b.instrs.deinit();
        }
        self.blocks.deinit();
        self.var_map.deinit();
        self.type_map.deinit(self.allocator);
        self.resource_format_map.deinit(self.allocator);
    }

    fn curKind(self: *const Parser) TokenKind {
        return self.tokens[self.pos].kind;
    }

    fn curText(self: *const Parser) []const u8 {
        const t = self.tokens[self.pos];
        return self.source[t.start..t.end];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn expect(self: *Parser, kind: TokenKind) ParserError!void {
        if (self.curKind() != kind) return error.UnexpectedToken;
        self.advance();
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.curKind() == kind) {
            self.advance();
            return true;
        }
        return false;
    }

    fn tokenText(self: *const Parser, t: Token) []const u8 {
        return self.source[t.start..t.end];
    }

    fn emit(self: *Parser, op: gpu_ir.Op, ty: gpu_ir.TypeRef, operands: []const gpu_ir.ValueId, data: gpu_ir.IrInst.Data) !gpu_ir.ValueId {
        const result = self.next_value_id;
        self.next_value_id += 1;
        const ops = try self.allocator.dupe(gpu_ir.ValueId, operands);
        try self.blocks.items[self.cur_block_idx].instrs.append(.{
            .op = op,
            .ty = ty,
            .result = result,
            .operands = ops,
            .data = data,
        });
        self.type_map.put(self.allocator, result, ty) catch {};
        return result;
    }

    fn addBlock(self: *Parser, label: []const u8) !gpu_ir.BlockId {
        const id = self.next_block_id;
        self.next_block_id += 1;
        try self.blocks.append(.{
            .label = try self.allocator.dupe(u8, label),
            .instrs = std.ArrayList(gpu_ir.IrInst).init(self.allocator),
            .next_value_id = 0,
        });
        return id;
    }

    fn curBlock(self: *Parser) *gpu_ir.IrBasicBlock {
        return &self.blocks.items[self.cur_block_idx];
    }

    fn setCurBlock(self: *Parser, idx: usize) void {
        self.cur_block_idx = idx;
    }

    fn lookupResourceOrCbuffer(self: *Parser, name: []const u8) ?VarEntry {
        for (self.resources) |res| {
            if (std.mem.eql(u8, res.name, name)) {
                const name_dup = self.allocator.dupe(u8, res.name) catch return null;
                const val_id = self.emit(.load, res.type_ref, &.{}, .{ .string = name_dup }) catch return null;
                self.resource_format_map.put(self.allocator, val_id, res.format) catch {};
                return VarEntry{ .value_id = val_id, .type_ref = res.type_ref, .is_array = false, .array_dims = &.{} };
            }
        }
        for (self.cbuffer) |mem| {
            if (std.mem.eql(u8, mem.name, name)) {
                const name_dup = self.allocator.dupe(u8, mem.name) catch return null;
                const val_id = self.emit(.load, mem.type_ref, &.{}, .{ .string = name_dup }) catch return null;
                return VarEntry{ .value_id = val_id, .type_ref = mem.type_ref, .is_array = false, .array_dims = &.{} };
            }
        }
        return null;
    }

    fn getVar(self: *Parser, name: []const u8) !VarEntry {
        if (self.var_map.get(name)) |entry| return entry;
        if (self.lookupResourceOrCbuffer(name)) |entry| {
            try self.var_map.put(name, entry);
            return entry;
        }
        // Unknown identifier — treat as HLSL builtin (DispatchThreadId, lerp, saturate, etc.)
        const name_dup = try self.allocator.dupe(u8, name);
        const val_id = try self.emit(.load, .f32, &.{}, .{ .string = name_dup });
        return VarEntry{ .value_id = val_id, .type_ref = .f32, .is_array = false, .array_dims = &.{} };
    }

    fn getType(self: *const Parser, id: gpu_ir.ValueId) gpu_ir.TypeRef {
        return self.type_map.get(id) orelse .f32;
    }

    fn isVectorType(ty: gpu_ir.TypeRef) bool {
        return switch (ty) {
            .vec2f, .vec3f, .vec4f, .vec2i, .vec3i, .vec4i, .vec2u, .vec3u, .vec4u => true,
            else => false,
        };
    }

    fn scalarTypeOf(ty: gpu_ir.TypeRef) gpu_ir.TypeRef {
        return switch (ty) {
            .vec2f, .vec3f, .vec4f => .f32,
            .vec2i, .vec3i, .vec4i => .i32,
            .vec2u, .vec3u, .vec4u => .u32,
            else => ty,
        };
    }

    fn inferBinaryResultType(self: *const Parser, lhs: gpu_ir.ValueId, rhs: gpu_ir.ValueId) gpu_ir.TypeRef {
        const lhs_t = self.getType(lhs);
        const rhs_t = self.getType(rhs);
        if (isVectorType(lhs_t)) return lhs_t;
        if (isVectorType(rhs_t)) return rhs_t;
        if (lhs_t == .f32 or rhs_t == .f32) return .f32;
        if (lhs_t == .i32 or rhs_t == .i32) return .i32;
        return .u32;
    }

    fn parseBodyInternal(self: *Parser) ParserError!void {
        while (self.curKind() != .eof) {
            try self.parseStatement();
        }
    }

    fn parseStatement(self: *Parser) ParserError!void {
        if (self.curKind() == .eof) return;

        if (self.curKind() == .lbracket) {
            const saved = self.pos;
            self.advance();
            if (self.curKind() == .kw_unroll or self.curKind() == .kw_branch or self.curKind() == .kw_flatten) {
                self.advance();
                if (self.curKind() == .rbracket) {
                    self.advance();
                    return self.parseAttrStmt();
                }
            }
            self.pos = saved;
        }

        switch (self.curKind()) {
            .kw_if => return self.parseIfStmt(),
            .kw_for => return self.parseForStmt(),
            .kw_while => return self.parseWhileStmt(),
            .kw_return => return self.parseReturnStmt(),
            .kw_unroll, .kw_branch, .kw_flatten => return self.parseAttrStmt(),
            .lbrace => return self.parseBlockStmt(),
            .type_name => return self.parseVarDeclStmt(),
            .semicolon => {
                self.advance();
                return;
            },
            else => return self.parseExprStmt(),
        }
    }

    fn parseVarDeclStmt(self: *Parser) ParserError!void {
        const type_name = self.curText();
        const type_ref = typeRefFromName(type_name) orelse return error.UnknownType;
        self.advance();

        const name = self.curText();
        try self.expect(.identifier);

        var array_dims_list = std.ArrayList(u32).init(self.allocator);
        defer array_dims_list.deinit();

        while (self.curKind() == .lbracket) {
            self.advance();
            const dim_str = self.curText();
            const dim = try std.fmt.parseInt(u32, dim_str, 10);
            self.advance();
            try self.expect(.rbracket);
            try array_dims_list.append(dim);
        }

        const is_array = array_dims_list.items.len > 0;
        const array_dims = if (is_array) try self.allocator.dupe(u32, array_dims_list.items) else &.{};

        if (self.curKind() == .assign) {
            self.advance();
            const init_val = try self.parseExpr();
            try self.var_map.put(name, .{
                .value_id = init_val,
                .type_ref = type_ref,
                .is_array = is_array,
                .array_dims = array_dims,
            });
        } else {
            const name_dup = try self.allocator.dupe(u8, name);
            const val_id = try self.emit(.load, type_ref, &.{}, .{ .string = name_dup });
            try self.var_map.put(name, .{
                .value_id = val_id,
                .type_ref = type_ref,
                .is_array = is_array,
                .array_dims = array_dims,
            });
            try self.locals.append(.{
                .name = name_dup,
                .type_ref = type_ref,
                .array_dims = array_dims,
            });
        }

        while (self.curKind() == .comma) {
            self.advance();
            const next_name = self.curText();
            try self.expect(.identifier);

            if (self.curKind() == .assign) {
                self.advance();
                const init_val = try self.parseExpr();
                try self.var_map.put(next_name, .{
                    .value_id = init_val,
                    .type_ref = type_ref,
                    .is_array = false,
                    .array_dims = &.{},
                });
            } else {
                const name_dup = try self.allocator.dupe(u8, next_name);
                const val_id = try self.emit(.load, type_ref, &.{}, .{ .string = name_dup });
                try self.var_map.put(next_name, .{
                    .value_id = val_id,
                    .type_ref = type_ref,
                    .is_array = false,
                    .array_dims = &.{},
                });
                try self.locals.append(.{
                    .name = name_dup,
                    .type_ref = type_ref,
                    .array_dims = &.{},
                });
            }
        }

        try self.expect(.semicolon);
    }

    fn parseExprStmt(self: *Parser) ParserError!void {
        if (self.curKind() == .identifier) {
            const saved_pos = self.pos;

            const name = self.curText();
            self.advance();

            if (self.curKind() == .lbracket) {
                self.pos = saved_pos;
                return self.parseArrayAssignStmt();
            }

            if (self.curKind() == .dot) {
                self.advance();
                _ = self.curText();
                try self.expect(.identifier);
                if (self.curKind() == .lparen) {
                    // Method call statement: obj.method(args);
                    self.pos = saved_pos;
                    _ = try self.parseExpr();
                    try self.expect(.semicolon);
                    return;
                }
                self.pos = saved_pos;
                return self.parseMemberAssignStmt();
            }

            if (self.curKind() == .assign or self.curKind() == .pluseq or self.curKind() == .minuseq or self.curKind() == .stareq or self.curKind() == .slasheq or self.curKind() == .percenteq) {
                const assign_kind = self.curKind();
                self.advance();
                const rhs = try self.parseExpr();
                try self.expect(.semicolon);

                if (self.var_map.get(name)) |entry| {
                    switch (assign_kind) {
                        .assign => {
                            try self.var_map.put(name, .{ .value_id = rhs, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .pluseq => {
                            const new_val = try self.emit(.add, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(name, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .minuseq => {
                            const new_val = try self.emit(.sub, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(name, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .stareq => {
                            const new_val = try self.emit(.mul, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(name, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .slasheq => {
                            const new_val = try self.emit(.div, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(name, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .percenteq => {
                            const new_val = try self.emit(.mod, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(name, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        else => unreachable,
                    }
                }
                return;
            }

            self.pos = saved_pos;
        }

        const val = try self.parseExpr();
        if (self.curKind() == .assign or self.curKind() == .pluseq or self.curKind() == .minuseq or self.curKind() == .stareq or self.curKind() == .slasheq or self.curKind() == .percenteq) {
            const name = self.tryGetVariableName(val);
            if (name) |n| {
                const assign_kind = self.curKind();
                self.advance();
                const rhs = try self.parseExpr();
                if (self.var_map.get(n)) |entry| {
                    switch (assign_kind) {
                        .assign => try self.var_map.put(n, .{ .value_id = rhs, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims }),
                        .pluseq => {
                            const new_val = try self.emit(.add, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(n, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .minuseq => {
                            const new_val = try self.emit(.sub, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(n, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .stareq => {
                            const new_val = try self.emit(.mul, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(n, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .slasheq => {
                            const new_val = try self.emit(.div, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(n, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        .percenteq => {
                            const new_val = try self.emit(.mod, entry.type_ref, &.{ entry.value_id, rhs }, .{ .none = {} });
                            try self.var_map.put(n, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                        },
                        else => unreachable,
                    }
                }
            }
        }
        if (self.curKind() != .eof) {
            try self.expect(.semicolon);
        }
    }

    fn tryGetVariableName(self: *Parser, val_id: gpu_ir.ValueId) ?[]const u8 {
        var it = self.var_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.value_id == val_id) return entry.key_ptr.*;
        }
        return null;
    }

    fn parseArrayAssignStmt(self: *Parser) ParserError!void {
        const name = self.curText();
        try self.expect(.identifier);

        var indices = std.ArrayList(gpu_ir.ValueId).init(self.allocator);
        defer indices.deinit();

        while (self.curKind() == .lbracket) {
            self.advance();
            const idx = try self.parseExpr();
            try indices.append(idx);
            try self.expect(.rbracket);
        }

        const assign_kind = self.curKind();
        if (assign_kind == .assign or assign_kind == .pluseq or assign_kind == .minuseq or assign_kind == .stareq or assign_kind == .slasheq) {
            self.advance();
            const rhs = try self.parseExpr();
            try self.expect(.semicolon);

            const entry = try self.getVar(name);
            const idx_slice = try indices.toOwnedSlice();
            const all_ops = try self.allocator.alloc(gpu_ir.ValueId, 1 + idx_slice.len + 1);
            all_ops[0] = entry.value_id;
            for (idx_slice, 0..) |idx_val, j| all_ops[1 + j] = idx_val;
            all_ops[1 + idx_slice.len] = rhs;

            const name_dup = try self.allocator.dupe(u8, name);
            _ = try self.emit(.store, entry.type_ref, all_ops, .{ .string = name_dup });
            return;
        }

        return error.ExpectedExpression;
    }

    fn parseMemberAssignStmt(self: *Parser) ParserError!void {
        const name = self.curText();
        try self.expect(.identifier);
        try self.expect(.dot);

        const member = self.curText();
        try self.expect(.identifier);

        if (self.curKind() == .assign) {
            self.advance();
            const rhs = try self.parseExpr();
            try self.expect(.semicolon);

            const entry = try self.getVar(name);
            const sw = getSwizzleMap(member);
            if (sw.count == 0) return error.InvalidAssignment;

            const member_scalar = scalarTypeOf(entry.type_ref);
            var comps = try self.allocator.alloc(gpu_ir.ValueId, 4);

            var used_rgb = [_]bool{ false, false, false, false };

            for (sw.indices[0..sw.count], 0..) |comp_idx, k| {
                used_rgb[comp_idx] = true;
                const comp = try self.emit(.extract, member_scalar, &.{ rhs }, .{ .extract_info = .{ .index = @intCast(k) } });
                comps[comp_idx] = comp;
            }

            for (0..4) |i| {
                if (!used_rgb[i]) {
                    comps[i] = try self.emit(.extract, member_scalar, &.{ entry.value_id }, .{ .extract_info = .{ .index = @intCast(i) } });
                }
            }

            const new_val = try self.emit(.composite, entry.type_ref, comps, .{ .composite_info = .{ .count = 4 } });
            try self.var_map.put(name, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
            return;
        }

        return error.ExpectedExpression;
    }

    fn parseIfStmt(self: *Parser) ParserError!void {
        try self.expect(.kw_if);
        try self.expect(.lparen);
        const cond_val = try self.parseExpr();
        try self.expect(.rparen);

        const before_then = try cloneVarMap(self.allocator, &self.var_map);

        const then_block_id = self.next_block_id;
        const then_idx = self.blocks.items.len;
        _ = try self.addBlock("if.then");
        const else_block_id = self.next_block_id;
        const else_idx = self.blocks.items.len;
        _ = try self.addBlock("if.else");
        const merge_block_id = self.next_block_id;
        const merge_idx = self.blocks.items.len;
        _ = try self.addBlock("if.merge");

        {
            const block = self.curBlock();
            const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{cond_val});
            try block.instrs.append(.{
                .op = .branch,
                .ty = .void,
                .result = self.next_value_id,
                .operands = ops,
                .data = .{ .cond_branch = .{
                    .cond = cond_val,
                    .then_block = then_block_id,
                    .else_block = else_block_id,
                } },
            });
            self.next_value_id += 1;
        }

        self.setCurBlock(then_idx);
        if (self.curKind() == .lbrace) {
            self.advance();
            var brace_depth: u32 = 1;
            while (self.curKind() != .eof and brace_depth > 0) {
                if (self.curKind() == .lbrace) brace_depth += 1;
                if (self.curKind() == .rbrace) brace_depth -= 1;
                if (brace_depth == 0) break;
                try self.parseStatement();
            }
            if (self.curKind() == .rbrace) self.advance();
        } else {
            try self.parseStatement();
        }
        {
            const cb = self.curBlock();
            if (cb.instrs.items.len == 0 or cb.instrs.getLast().op != .ret) {
                _ = try self.emit(.ret, .void, &.{}, .{ .block_target = merge_block_id });
            }
        }

        const then_map = try cloneVarMap(self.allocator, &self.var_map);
        self.var_map.deinit();
        self.var_map = try cloneVarMap(self.allocator, &before_then);

        self.setCurBlock(else_idx);
        if (self.curKind() == .kw_else) {
            self.advance();
            if (self.curKind() == .kw_if) {
                try self.parseIfStmt();
            } else if (self.curKind() == .lbrace) {
                self.advance();
                var brace_depth: u32 = 1;
                while (self.curKind() != .eof and brace_depth > 0) {
                    if (self.curKind() == .lbrace) brace_depth += 1;
                    if (self.curKind() == .rbrace) brace_depth -= 1;
                    if (brace_depth == 0) break;
                    try self.parseStatement();
                }
                if (self.curKind() == .rbrace) self.advance();
            } else {
                try self.parseStatement();
            }
        }
        {
            const cb = self.curBlock();
            if (cb.instrs.items.len == 0 or cb.instrs.getLast().op != .ret) {
                _ = try self.emit(.ret, .void, &.{}, .{ .block_target = merge_block_id });
            }
        }

        {
            var it = then_map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.is_array) continue;
                if (self.var_map.get(entry.key_ptr.*)) |else_entry| {
                    if (entry.value_ptr.value_id != else_entry.value_id) {
                        const incoming = try self.allocator.alloc(PhiIncoming, 2);
                        incoming[0] = .{ .value = entry.value_ptr.value_id, .block = then_block_id };
                        incoming[1] = .{ .value = else_entry.value_id, .block = else_block_id };
                        const phi_result = self.next_value_id;
                        self.next_value_id += 1;
                        const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{ entry.value_ptr.value_id, else_entry.value_id });
                        try self.blocks.items[merge_idx].instrs.append(.{
                            .op = .phi,
                            .ty = entry.value_ptr.type_ref,
                            .result = phi_result,
                            .operands = ops,
                            .data = .{ .phi_incoming = incoming },
                        });
                        try self.var_map.put(entry.key_ptr.*, .{
                            .value_id = phi_result,
                            .type_ref = entry.value_ptr.type_ref,
                            .is_array = entry.value_ptr.is_array, .array_dims = entry.value_ptr.array_dims,
                        });
                    }
                } else {
                    try self.var_map.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }

        self.setCurBlock(merge_idx);
    }

    fn parseForStmt(self: *Parser) ParserError!void {
        try self.expect(.kw_for);
        try self.expect(.lparen);

        const before_loop = try cloneVarMap(self.allocator, &self.var_map);
        _ = &before_loop;

        if (self.curKind() != .semicolon) {
            if (self.curKind() == .type_name) {
                try self.parseVarDeclStmt();
            } else {
                _ = try self.parseExpr();
                try self.expect(.semicolon);
            }
        } else {
            try self.expect(.semicolon);
        }

        const before_cond = try cloneVarMap(self.allocator, &self.var_map);

        const preheader_block_id = @as(u32, @intCast(self.blocks.items.len - 1));
        const header_idx = self.blocks.items.len;
        const header_block_id = self.addBlock("for.header") catch return;
        const body_idx = self.blocks.items.len;
        const body_block_id = self.addBlock("for.body") catch return;
        const continue_idx = self.blocks.items.len;
        const continue_block_id = self.addBlock("for.continue") catch return;
        const exit_idx = self.blocks.items.len;
        const exit_block_id = self.addBlock("for.exit") catch return;

        {
            const block = self.curBlock();
            const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{});
            try block.instrs.append(.{
                .op = .ret,
                .ty = .void,
                .result = self.next_value_id,
                .operands = ops,
                .data = .{ .block_target = header_block_id },
            });
            self.next_value_id += 1;
        }

        self.setCurBlock(header_idx);

        const PendingPhiUpdate = struct { block_idx: usize, instr_idx: usize, var_name: []const u8, before_val: gpu_ir.ValueId };
        var pending_phis = std.ArrayList(PendingPhiUpdate).init(self.allocator);
        defer pending_phis.deinit();
        {
            var it = before_cond.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.is_array) continue;
                const incoming = try self.allocator.alloc(PhiIncoming, 2);
                incoming[0] = .{ .value = entry.value_ptr.value_id, .block = preheader_block_id };
                incoming[1] = .{ .value = entry.value_ptr.value_id, .block = header_block_id };
                const phi_result = self.next_value_id;
                self.next_value_id += 1;
                const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{ entry.value_ptr.value_id, entry.value_ptr.value_id });
                const instr_idx = self.blocks.items[header_idx].instrs.items.len;
                try self.blocks.items[header_idx].instrs.append(.{
                    .op = .phi,
                    .ty = entry.value_ptr.type_ref,
                    .result = phi_result,
                    .operands = ops,
                    .data = .{ .phi_incoming = incoming },
                });
                self.type_map.put(self.allocator, phi_result, entry.value_ptr.type_ref) catch {};
                try pending_phis.append(.{
                    .block_idx = header_idx,
                    .instr_idx = instr_idx,
                    .var_name = entry.key_ptr.*,
                    .before_val = entry.value_ptr.value_id,
                });
                try self.var_map.put(entry.key_ptr.*, .{
                    .value_id = phi_result,
                    .type_ref = entry.value_ptr.type_ref,
                    .is_array = entry.value_ptr.is_array,
                    .array_dims = entry.value_ptr.array_dims,
                });
            }
        }

        var cond_val: gpu_ir.ValueId = 0;
        var has_cond = false;
        if (self.curKind() != .semicolon) {
            cond_val = try self.parseExpr();
            has_cond = true;
        }
        try self.expect(.semicolon);

        self.setCurBlock(continue_idx);
        if (self.curKind() != .rparen) {
            while (true) {
                _ = try self.parseExpr();
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.rparen);
        self.setCurBlock(header_idx);

        if (has_cond) {
            const merged_cond = cond_val;
            const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{merged_cond});
            try self.curBlock().instrs.append(.{
                .op = .branch,
                .ty = .void,
                .result = self.next_value_id,
                .operands = ops,
                .data = .{ .cond_branch = .{
                    .cond = merged_cond,
                    .then_block = body_block_id,
                    .else_block = exit_block_id,
                } },
            });
            self.next_value_id += 1;
        } else {
            const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{});
            try self.curBlock().instrs.append(.{
                .op = .ret,
                .ty = .void,
                .result = self.next_value_id,
                .operands = ops,
                .data = .{ .block_target = body_block_id },
            });
            self.next_value_id += 1;
        }

        self.setCurBlock(body_idx);
        if (self.curKind() == .lbrace) {
            self.advance();
            var brace_depth: u32 = 1;
            while (self.curKind() != .eof and brace_depth > 0) {
                if (self.curKind() == .lbrace) brace_depth += 1;
                if (self.curKind() == .rbrace) brace_depth -= 1;
                if (brace_depth == 0) break;
                try self.parseStatement();
            }
            if (self.curKind() == .rbrace) self.advance();
        } else {
            try self.parseStatement();
        }
        {
            const cb = self.curBlock();
            if (cb.instrs.items.len == 0 or cb.instrs.getLast().op != .ret) {
                _ = try self.emit(.ret, .void, &.{}, .{ .block_target = continue_block_id });
            }
        }

        self.setCurBlock(continue_idx);
        {
            const cb = self.curBlock();
            if (cb.instrs.items.len == 0 or cb.instrs.getLast().op != .ret) {
                _ = try self.emit(.ret, .void, &.{}, .{ .block_target = header_block_id });
            }
        }

        for (pending_phis.items) |pp| {
            if (self.var_map.get(pp.var_name)) |after| {
                if (after.value_id != pp.before_val) {
                    const phi_inst = &self.blocks.items[pp.block_idx].instrs.items[pp.instr_idx];
                    if (phi_inst.operands.len >= 2) {
                        self.allocator.free(phi_inst.operands);
                    }
                    phi_inst.operands = try self.allocator.dupe(gpu_ir.ValueId, &.{ pp.before_val, after.value_id });
                    if (phi_inst.data == .phi_incoming) {
                        self.allocator.free(phi_inst.data.phi_incoming);
                    }
                    const incoming = try self.allocator.alloc(PhiIncoming, 2);
                    incoming[0] = .{ .value = pp.before_val, .block = preheader_block_id };
                    incoming[1] = .{ .value = after.value_id, .block = continue_block_id };
                    phi_inst.data = .{ .phi_incoming = incoming };
                    phi_inst.ty = after.type_ref;
                    phi_inst.result = phi_inst.result;
                }
            }
        }

        for (pending_phis.items) |pp| {
            const phi_inst = &self.blocks.items[pp.block_idx].instrs.items[pp.instr_idx];
            if (self.var_map.getPtr(pp.var_name)) |entry| {
                entry.value_id = phi_inst.result;
            }
        }

        self.setCurBlock(exit_idx);
    }

    fn parseWhileStmt(self: *Parser) ParserError!void {
        try self.expect(.kw_while);
        try self.expect(.lparen);

        const before_loop = try cloneVarMap(self.allocator, &self.var_map);

        const preheader_block_id = @as(u32, @intCast(self.blocks.items.len - 1));
        const header_idx = self.blocks.items.len;
        const header_block_id = self.addBlock("while.header") catch return;
        const body_idx = self.blocks.items.len;
        const body_block_id = self.addBlock("while.body") catch return;
        const exit_idx = self.blocks.items.len;
        const exit_block_id = self.addBlock("while.exit") catch return;

        {
            const block = self.curBlock();
            const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{});
            try block.instrs.append(.{
                .op = .ret,
                .ty = .void,
                .result = self.next_value_id,
                .operands = ops,
                .data = .{ .block_target = header_block_id },
            });
            self.next_value_id += 1;
        }

        self.setCurBlock(header_idx);

        const PendingPhiUpdate = struct { block_idx: usize, instr_idx: usize, var_name: []const u8, before_val: gpu_ir.ValueId };
        var pending_phis = std.ArrayList(PendingPhiUpdate).init(self.allocator);
        defer pending_phis.deinit();

        {
            var it = before_loop.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.is_array) continue;
                const incoming = try self.allocator.alloc(PhiIncoming, 2);
                incoming[0] = .{ .value = entry.value_ptr.value_id, .block = preheader_block_id };
                incoming[1] = .{ .value = entry.value_ptr.value_id, .block = header_block_id };
                const phi_result = self.next_value_id;
                self.next_value_id += 1;
                const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{ entry.value_ptr.value_id, entry.value_ptr.value_id });
                const instr_idx = self.blocks.items[header_idx].instrs.items.len;
                try self.blocks.items[header_idx].instrs.append(.{
                    .op = .phi,
                    .ty = entry.value_ptr.type_ref,
                    .result = phi_result,
                    .operands = ops,
                    .data = .{ .phi_incoming = incoming },
                });
                self.type_map.put(self.allocator, phi_result, entry.value_ptr.type_ref) catch {};
                try pending_phis.append(.{
                    .block_idx = header_idx,
                    .instr_idx = instr_idx,
                    .var_name = entry.key_ptr.*,
                    .before_val = entry.value_ptr.value_id,
                });
                try self.var_map.put(entry.key_ptr.*, .{
                    .value_id = phi_result,
                    .type_ref = entry.value_ptr.type_ref,
                    .is_array = entry.value_ptr.is_array, .array_dims = entry.value_ptr.array_dims,
                });
            }
        }

        if (self.curKind() != .rparen) {
            const cond_val = try self.parseExpr();
            try self.expect(.rparen);
            const ops = try self.allocator.dupe(gpu_ir.ValueId, &.{cond_val});
            try self.curBlock().instrs.append(.{
                .op = .branch,
                .ty = .void,
                .result = self.next_value_id,
                .operands = ops,
                .data = .{ .cond_branch = .{
                    .cond = cond_val,
                    .then_block = body_block_id,
                    .else_block = exit_block_id,
                } },
            });
            self.next_value_id += 1;
        } else {
            try self.expect(.rparen);
        }

        self.setCurBlock(body_idx);
        if (self.curKind() == .lbrace) {
            self.advance();
            var brace_depth: u32 = 1;
            while (self.curKind() != .eof and brace_depth > 0) {
                if (self.curKind() == .lbrace) brace_depth += 1;
                if (self.curKind() == .rbrace) brace_depth -= 1;
                if (brace_depth == 0) break;
                try self.parseStatement();
            }
            if (self.curKind() == .rbrace) self.advance();
        } else {
            try self.parseStatement();
        }
        {
            const cb = self.curBlock();
            if (cb.instrs.items.len == 0 or cb.instrs.getLast().op != .ret) {
                _ = try self.emit(.ret, .void, &.{}, .{ .block_target = header_block_id });
            }
        }

        for (pending_phis.items) |pp| {
            if (self.var_map.get(pp.var_name)) |after| {
                if (after.value_id != pp.before_val) {
                    const phi_inst = &self.blocks.items[pp.block_idx].instrs.items[pp.instr_idx];
                    if (phi_inst.operands.len >= 2) {
                        self.allocator.free(phi_inst.operands);
                    }
                    phi_inst.operands = try self.allocator.dupe(gpu_ir.ValueId, &.{ pp.before_val, after.value_id });
                    if (phi_inst.data == .phi_incoming) {
                        self.allocator.free(phi_inst.data.phi_incoming);
                    }
                    const incoming = try self.allocator.alloc(PhiIncoming, 2);
                    incoming[0] = .{ .value = pp.before_val, .block = preheader_block_id };
                    incoming[1] = .{ .value = after.value_id, .block = body_block_id };
                    phi_inst.data = .{ .phi_incoming = incoming };
                    phi_inst.ty = after.type_ref;
                }
            }
        }

        self.setCurBlock(exit_idx);
    }

    fn parseReturnStmt(self: *Parser) ParserError!void {
        try self.expect(.kw_return);
        if (self.curKind() != .semicolon) {
            const ret_val = try self.parseExpr();
            try self.expect(.semicolon);
            _ = try self.emit(.ret, .void, &.{ret_val}, .{ .none = {} });
        } else {
            try self.expect(.semicolon);
            _ = try self.emit(.ret, .void, &.{}, .{ .none = {} });
        }
    }

    fn parseAttrStmt(self: *Parser) ParserError!void {
        if (self.curKind() == .kw_unroll or self.curKind() == .kw_branch or self.curKind() == .kw_flatten) {
            self.advance();
        }
        if (self.curKind() == .kw_for) return self.parseForStmt();
        if (self.curKind() == .kw_while) return self.parseWhileStmt();
        try self.parseStatement();
    }

    fn parseBlockStmt(self: *Parser) ParserError!void {
        try self.expect(.lbrace);
        var brace_depth: u32 = 1;
        while (self.curKind() != .eof and brace_depth > 0) {
            if (self.curKind() == .lbrace) brace_depth += 1;
            if (self.curKind() == .rbrace) brace_depth -= 1;
            if (brace_depth == 0) break;
            try self.parseStatement();
        }
        try self.expect(.rbrace);
    }

    fn parseExpr(self: *Parser) ParserError!gpu_ir.ValueId {
        return self.parseAssignment();
    }

    fn parseAssignment(self: *Parser) ParserError!gpu_ir.ValueId {
        const lhs = try self.parseTernary();
        if (self.match(.assign)) {
            const rhs = try self.parseAssignment();
            if (self.tryGetVariableName(lhs)) |name| {
                if (self.var_map.get(name)) |entry| {
                    try self.var_map.put(name, .{ .value_id = rhs, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                }
            }
            return rhs;
        }
        if (self.match(.pluseq)) {
            const rhs = try self.parseAssignment();
            const result = try self.emit(.add, .f32, &.{ lhs, rhs }, .{ .none = {} });
            if (self.tryGetVariableName(lhs)) |name| {
                if (self.var_map.get(name)) |entry| {
                    try self.var_map.put(name, .{ .value_id = result, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                }
            }
            return result;
        }
        if (self.match(.minuseq)) {
            const rhs = try self.parseAssignment();
            const result = try self.emit(.sub, .f32, &.{ lhs, rhs }, .{ .none = {} });
            if (self.tryGetVariableName(lhs)) |name| {
                if (self.var_map.get(name)) |entry| {
                    try self.var_map.put(name, .{ .value_id = result, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                }
            }
            return result;
        }
        if (self.match(.stareq)) {
            const rhs = try self.parseAssignment();
            const result = try self.emit(.mul, .f32, &.{ lhs, rhs }, .{ .none = {} });
            if (self.tryGetVariableName(lhs)) |name| {
                if (self.var_map.get(name)) |entry| {
                    try self.var_map.put(name, .{ .value_id = result, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                }
            }
            return result;
        }
        if (self.match(.slasheq)) {
            const rhs = try self.parseAssignment();
            const result = try self.emit(.div, .f32, &.{ lhs, rhs }, .{ .none = {} });
            if (self.tryGetVariableName(lhs)) |name| {
                if (self.var_map.get(name)) |entry| {
                    try self.var_map.put(name, .{ .value_id = result, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                }
            }
            return result;
        }
        if (self.match(.percenteq)) {
            const rhs = try self.parseAssignment();
            const result = try self.emit(.mod, .f32, &.{ lhs, rhs }, .{ .none = {} });
            if (self.tryGetVariableName(lhs)) |name| {
                if (self.var_map.get(name)) |entry| {
                    try self.var_map.put(name, .{ .value_id = result, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims });
                }
            }
            return result;
        }
        return lhs;
    }

    fn parseTernary(self: *Parser) ParserError!gpu_ir.ValueId {
        const cond = try self.parseLogicalOr();
        if (self.match(.question)) {
            const true_val = try self.parseTernary();
            try self.expect(.colon);
            const false_val = try self.parseTernary();
            return try self.emit(.select, .f32, &.{ cond, true_val, false_val }, .{ .none = {} });
        }
        return cond;
    }

    fn parseLogicalOr(self: *Parser) !gpu_ir.ValueId {
        var lhs = try self.parseLogicalAnd();
        while (self.match(.oror)) {
            const rhs = try self.parseLogicalAnd();
            lhs = try self.emit(.or_op, .u32, &.{ lhs, rhs }, .{ .none = {} });
        }
        return lhs;
    }

    fn parseLogicalAnd(self: *Parser) !gpu_ir.ValueId {
        var lhs = try self.parseEquality();
        while (self.match(.andand)) {
            const rhs = try self.parseEquality();
            lhs = try self.emit(.and_op, .u32, &.{ lhs, rhs }, .{ .none = {} });
        }
        return lhs;
    }

    fn parseEquality(self: *Parser) !gpu_ir.ValueId {
        var lhs = try self.parseRelational();
        while (true) {
            if (self.match(.eqeq)) {
                const rhs = try self.parseRelational();
                lhs = try self.emit(.eq, .u32, &.{ lhs, rhs }, .{ .none = {} });
            } else if (self.match(.neq)) {
                const rhs = try self.parseRelational();
                lhs = try self.emit(.ne, .u32, &.{ lhs, rhs }, .{ .none = {} });
            } else break;
        }
        return lhs;
    }

    fn parseRelational(self: *Parser) !gpu_ir.ValueId {
        var lhs = try self.parseAdditive();
        while (true) {
            if (self.match(.lt)) {
                const rhs = try self.parseAdditive();
                lhs = try self.emit(.lt, .u32, &.{ lhs, rhs }, .{ .none = {} });
            } else if (self.match(.gt)) {
                const rhs = try self.parseAdditive();
                lhs = try self.emit(.gt, .u32, &.{ lhs, rhs }, .{ .none = {} });
            } else if (self.match(.lte)) {
                const rhs = try self.parseAdditive();
                lhs = try self.emit(.le, .u32, &.{ lhs, rhs }, .{ .none = {} });
            } else if (self.match(.gte)) {
                const rhs = try self.parseAdditive();
                lhs = try self.emit(.ge, .u32, &.{ lhs, rhs }, .{ .none = {} });
            } else break;
        }
        return lhs;
    }

    fn parseAdditive(self: *Parser) !gpu_ir.ValueId {
        var lhs = try self.parseMultiplicative();
        while (true) {
            if (self.match(.plus)) {
                const rhs = try self.parseMultiplicative();
                const result_ty = self.inferBinaryResultType(lhs, rhs);
                lhs = try self.emit(.add, result_ty, &.{ lhs, rhs }, .{ .none = {} });
            } else if (self.match(.minus)) {
                const rhs = try self.parseMultiplicative();
                const result_ty = self.inferBinaryResultType(lhs, rhs);
                lhs = try self.emit(.sub, result_ty, &.{ lhs, rhs }, .{ .none = {} });
            } else break;
        }
        return lhs;
    }

    fn parseMultiplicative(self: *Parser) !gpu_ir.ValueId {
        var lhs = try self.parseUnary();
        while (true) {
            if (self.match(.star)) {
                const rhs = try self.parseUnary();
                const result_ty = self.inferBinaryResultType(lhs, rhs);
                lhs = try self.emit(.mul, result_ty, &.{ lhs, rhs }, .{ .none = {} });
            } else if (self.match(.slash)) {
                const rhs = try self.parseUnary();
                const result_ty = self.inferBinaryResultType(lhs, rhs);
                lhs = try self.emit(.div, result_ty, &.{ lhs, rhs }, .{ .none = {} });
            } else if (self.match(.percent)) {
                const rhs = try self.parseUnary();
                const result_ty = self.inferBinaryResultType(lhs, rhs);
                lhs = try self.emit(.mod, result_ty, &.{ lhs, rhs }, .{ .none = {} });
            } else break;
        }
        return lhs;
    }

    fn updateVarForValue(self: *Parser, old_val: gpu_ir.ValueId, new_val: gpu_ir.ValueId) void {
        if (self.tryGetVariableName(old_val)) |name| {
            if (self.var_map.get(name)) |entry| {
                self.var_map.put(name, .{ .value_id = new_val, .type_ref = entry.type_ref, .is_array = entry.is_array, .array_dims = entry.array_dims }) catch {};
            }
        }
    }

    fn parseUnary(self: *Parser) ParserError!gpu_ir.ValueId {
        if (self.match(.plusplus)) {
            const operand = try self.parseUnary();
            const one = try self.emit(.@"const", .i32, &.{}, .{ .int_val = 1 });
            const result_ty = self.inferBinaryResultType(operand, one);
            const result = try self.emit(.add, result_ty, &.{ operand, one }, .{ .none = {} });
            self.updateVarForValue(operand, result);
            return result;
        }
        if (self.match(.minusminus)) {
            const operand = try self.parseUnary();
            const one = try self.emit(.@"const", .i32, &.{}, .{ .int_val = 1 });
            const result_ty = self.inferBinaryResultType(operand, one);
            const result = try self.emit(.sub, result_ty, &.{ operand, one }, .{ .none = {} });
            self.updateVarForValue(operand, result);
            return result;
        }
        if (self.match(.minus)) {
            const operand = try self.parseUnary();
            const operand_ty = self.getType(operand);
            const zero = switch (operand_ty) {
                .f32, .vec2f, .vec3f, .vec4f => try self.emit(.@"const", .f32, &.{}, .{ .float_val = 0.0 }),
                .i32, .vec2i, .vec3i, .vec4i => try self.emit(.@"const", .i32, &.{}, .{ .int_val = 0 }),
                else => try self.emit(.@"const", .u32, &.{}, .{ .int_val = 0 }),
            };
            return try self.emit(.sub, operand_ty, &.{ zero, operand }, .{ .none = {} });
        }
        if (self.match(.bang)) {
            const operand = try self.parseUnary();
            return try self.emit(.not, .u32, &.{operand}, .{ .none = {} });
        }
        if (self.match(.plus)) {
            return self.parseUnary();
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParserError!gpu_ir.ValueId {
        var val = try self.parsePrimary();

        while (true) {
            if (self.match(.lbracket)) {
                const idx = try self.parseExpr();
                try self.expect(.rbracket);
                const elem_type = self.getType(val);
                val = try self.emit(.call, elem_type, &.{ val, idx }, .{ .call_info = .{
                    .callee = try self.allocator.dupe(u8, "@array_get"),
                    .args = try self.allocator.dupe(gpu_ir.ValueId, &.{ val, idx }),
                } });
            } else if (self.match(.dot)) {
                const member = self.curText();
                try self.expect(.identifier);

                if (isIntrinsicMethod(member)) {
                    try self.expect(.lparen);
                    var args = std.ArrayList(gpu_ir.ValueId).init(self.allocator);
                    defer args.deinit();
                    try args.append(val);
                    while (self.curKind() != .rparen and self.curKind() != .eof) {
                        const arg = try self.parseExpr();
                        try args.append(arg);
                        _ = self.match(.comma);
                    }
                    try self.expect(.rparen);
                    const args_slice = try args.toOwnedSlice();
                    const method_type: gpu_ir.TypeRef = if (std.mem.eql(u8, member, "GetDimensions")) .void else blk: {
                        break :blk self.resource_format_map.get(val) orelse .vec4f;
                    };
                    val = try self.emit(.call, method_type, args_slice, .{ .call_info = .{ .callee = try self.allocator.dupe(u8, member), .args = args_slice } });
                } else if (self.curKind() == .lparen) {
                    self.advance();
                    var args = std.ArrayList(gpu_ir.ValueId).init(self.allocator);
                    defer args.deinit();
                    try args.append(val);
                    while (self.curKind() != .rparen and self.curKind() != .eof) {
                        const arg = try self.parseExpr();
                        try args.append(arg);
                        _ = self.match(.comma);
                    }
                    try self.expect(.rparen);
                    const args_slice = try args.toOwnedSlice();
                    const call_type = if (self.func_types.get(member)) |t| t else if (args_slice.len > 1) self.getType(args_slice[1]) else self.getType(args_slice[0]);
                    val = try self.emit(.call, call_type, args_slice, .{ .call_info = .{ .callee = try self.allocator.dupe(u8, member), .args = args_slice } });
                } else if (isSwizzle(member)) {
                    val = try self.parseSwizzle(val, member);
                }
            } else if (self.match(.plusplus)) {
                const one = try self.emit(.@"const", .i32, &.{}, .{ .int_val = 1 });
                const result_ty = self.inferBinaryResultType(val, one);
                const new_val = try self.emit(.add, result_ty, &.{ val, one }, .{ .none = {} });
                self.updateVarForValue(val, new_val);
                // postfix ++ returns original value (val), not new_val
            } else if (self.match(.minusminus)) {
                const one = try self.emit(.@"const", .i32, &.{}, .{ .int_val = 1 });
                const result_ty = self.inferBinaryResultType(val, one);
                const new_val = try self.emit(.sub, result_ty, &.{ val, one }, .{ .none = {} });
                self.updateVarForValue(val, new_val);
                // postfix -- returns original value (val), not new_val
            } else {
                break;
            }
        }

        return val;
    }

    fn parsePrimary(self: *Parser) ParserError!gpu_ir.ValueId {
        const tok = self.tokens[self.pos];
        switch (tok.kind) {
            .int_literal => {
                self.advance();
                const text = self.tokenText(tok);
                const actual = if (text.len > 1 and text[text.len - 1] == 'u') text[0 .. text.len - 1] else text;
                const val = try std.fmt.parseInt(i64, actual, 10);
                return self.emit(.@"const", .i32, &.{}, .{ .int_val = val });
            },
            .float_literal => {
                self.advance();
                const text = self.tokenText(tok);
                const val = try std.fmt.parseFloat(f64, text);
                return self.emit(.@"const", .f32, &.{}, .{ .float_val = val });
            },
            .kw_true => {
                self.advance();
                return self.emit(.@"const", .u32, &.{}, .{ .int_val = 1 });
            },
            .kw_false => {
                self.advance();
                return self.emit(.@"const", .u32, &.{}, .{ .int_val = 0 });
            },
            .identifier => {
                self.advance();
                const name = self.tokenText(tok);

                // Check for direct function call: ident(args)
                if (self.curKind() == .lparen and self.var_map.get(name) == null and self.lookupResourceOrCbuffer(name) == null) {
                    self.advance();
                    var args = std.ArrayList(gpu_ir.ValueId).init(self.allocator);
                    defer args.deinit();
                    while (self.curKind() != .rparen and self.curKind() != .eof) {
                        const arg = try self.parseExpr();
                        try args.append(arg);
                        _ = self.match(.comma);
                    }
                    try self.expect(.rparen);
                    const args_slice = try args.toOwnedSlice();

                    // Wave intrinsic recognition
                    if (try self.tryEmitWaveIntrinsic(name, args_slice)) |result| {
                        return result;
                    }

                    const call_type = if (self.func_types.get(name)) |t| t else blk: {
                        var widest: gpu_ir.TypeRef = .f32;
                        for (args_slice) |a| {
                            const at = self.getType(a);
                            if (@intFromEnum(at) > @intFromEnum(widest)) widest = at;
                        }
                        break :blk widest;
                    };
                    return self.emit(.call, call_type, args_slice, .{ .call_info = .{ .callee = try self.allocator.dupe(u8, name), .args = args_slice } });
                }

                const entry = try self.getVar(name);
                return entry.value_id;
            },
            .type_name => {
                const type_name = self.tokenText(tok);
                self.advance();
                if (self.curKind() == .lparen) {
                    self.advance();
                    var args = std.ArrayList(gpu_ir.ValueId).init(self.allocator);
                    defer args.deinit();
                    while (self.curKind() != .rparen and self.curKind() != .eof) {
                        const arg = try self.parseExpr();
                        try args.append(arg);
                        _ = self.match(.comma);
                    }
                    try self.expect(.rparen);
                    const result_type = typeRefFromName(type_name) orelse .f32;
                    const args_slice = try args.toOwnedSlice();
                    return self.emit(.call, result_type, args_slice, .{ .call_info = .{ .callee = try self.allocator.dupe(u8, type_name), .args = args_slice } });
                }
                return error.ExpectedExpression;
            },
            .lparen => {
                self.advance();
                // C-style cast: (type_name) expr
                const saved = self.pos;
                if (self.curKind() == .type_name) {
                    const cast_name = self.curText();
                    const cast_type = typeRefFromName(cast_name);
                    self.advance();
                    if (self.curKind() == .rparen) {
                        self.advance();
                        const val = try self.parseUnary();
                        if (cast_type) |ct| {
                            return self.emit(.cast, ct, &.{val}, .{ .cast_info = .{ .from = .f32, .to = ct } });
                        }
                        return val;
                    }
                    self.pos = saved;
                }
                const val = try self.parseExpr();
                try self.expect(.rparen);
                return val;
            },
            else => return error.ExpectedExpression,
        }
    }

    fn parseSwizzle(self: *Parser, base: gpu_ir.ValueId, member: []const u8) !gpu_ir.ValueId {
        const sw = getSwizzleMap(member);
        const base_ty = self.getType(base);
        const scalar_ty = scalarTypeOf(base_ty);
        if (sw.count == 1) {
            return self.emit(.extract, scalar_ty, &.{base}, .{ .extract_info = .{ .index = sw.indices[0] } });
        }

        var components = std.ArrayList(gpu_ir.ValueId).init(self.allocator);
        defer components.deinit();
        for (sw.indices[0..sw.count]) |idx| {
            const comp = try self.emit(.extract, scalar_ty, &.{base}, .{ .extract_info = .{ .index = idx } });
            try components.append(comp);
        }
        const vec_type: gpu_ir.TypeRef = if (isVectorType(base_ty)) switch (sw.count) {
            2 => switch (base_ty) { .vec2f, .vec3f, .vec4f => .vec2f, .vec2i, .vec3i, .vec4i => .vec2i, .vec2u, .vec3u, .vec4u => .vec2u, else => .vec2f },
            3 => switch (base_ty) { .vec2f, .vec3f, .vec4f => .vec3f, .vec2i, .vec3i, .vec4i => .vec3i, .vec2u, .vec3u, .vec4u => .vec3u, else => .vec3f },
            4 => switch (base_ty) { .vec2f, .vec3f, .vec4f => .vec4f, .vec2i, .vec3i, .vec4i => .vec4i, .vec2u, .vec3u, .vec4u => .vec4u, else => .vec4f },
            else => scalar_ty,
        } else scalar_ty;
        const comps = try components.toOwnedSlice();
        return self.emit(.composite, vec_type, comps, .{ .composite_info = .{ .count = @intCast(sw.count) } });
    }

    fn tryEmitWaveIntrinsic(self: *Parser, name: []const u8, args: []const gpu_ir.ValueId) !?gpu_ir.ValueId {
        const op: gpu_ir.Op = if (std.mem.eql(u8, name, "WaveReadLaneFirst")) .wave_read_lane_first
        else if (std.mem.eql(u8, name, "WaveGetLaneIndex")) .wave_get_lane_index
        else if (std.mem.eql(u8, name, "WaveIsFirstLane")) .wave_is_first_lane
        else if (std.mem.eql(u8, name, "WaveActiveAllEqual")) .wave_active_all_equal
        else if (std.mem.eql(u8, name, "QuadReadAcrossX")) .quad_read_across_x
        else if (std.mem.eql(u8, name, "QuadReadAcrossY")) .quad_read_across_y
        else return null;

        const result_ty: gpu_ir.TypeRef = switch (op) {
            .wave_get_lane_index, .wave_is_first_lane, .wave_active_all_equal => .i32,
            else => if (args.len > 0) self.getType(args[0]) else .i32,
        };

        const src = if (args.len > 0) args[0] else 0;
        const val = try self.emit(op, result_ty, args, .{ .wave_op = .{ .source = src } });
        return @as(?gpu_ir.ValueId, val);
    }
};

const SwizzleResult = struct {
    indices: [4]u32,
    count: usize,
};

fn getSwizzleMap(name: []const u8) SwizzleResult {
    var result: SwizzleResult = .{ .indices = undefined, .count = 0 };
    if (name.len == 0 or name.len > 4) return result;
    for (name, 0..) |c, i| {
        const idx: u32 = switch (c) {
            'x', 'r' => 0,
            'y', 'g' => 1,
            'z', 'b' => 2,
            'w', 'a' => 3,
            else => return result,
        };
        result.indices[i] = idx;
    }
    result.count = name.len;
    return result;
}

fn isSwizzle(name: []const u8) bool {
    return getSwizzleMap(name).count > 0;
}

fn isIntrinsicMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "SampleLevel") or
        std.mem.eql(u8, name, "Sample") or
        std.mem.eql(u8, name, "Load") or
        std.mem.eql(u8, name, "GetDimensions") or
        std.mem.eql(u8, name, "Gather") or
        std.mem.eql(u8, name, "GatherRed") or
        std.mem.eql(u8, name, "GatherGreen") or
        std.mem.eql(u8, name, "GatherBlue") or
        std.mem.eql(u8, name, "GatherAlpha");
}

fn joinLines(allocator: Allocator, lines: []const []const u8) ![]const u8 {
    var total: usize = 0;
    for (lines) |line| total += line.len + 1;
    const buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (lines) |line| {
        @memcpy(buf[pos..][0..line.len], line);
        pos += line.len;
        buf[pos] = '\n';
        pos += 1;
    }
    return buf;
}

pub fn parseBody(allocator: Allocator, body_lines: []const []const u8, resources: []const gpu_ir.IrResourceDecl, cbuffer: []const gpu_ir.IrCbufferMember, func_types: std.StringHashMap(gpu_ir.TypeRef)) !gpu_ir.IrFunction {
    const source = try joinLines(allocator, body_lines);
    defer allocator.free(source);

    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);

    var p = Parser.init(allocator, source, tokens, resources, cbuffer, func_types);
    errdefer p.deinit();

    _ = try p.addBlock("entry");
    p.setCurBlock(0);

    try p.parseBodyInternal();

    const passthrough = std.ArrayList([]const u8).init(allocator);
    const globals = std.ArrayList([]const u8).init(allocator);

    return gpu_ir.IrFunction{
        .name = "",
        .kernel_name = "",
        .blocks = p.blocks,
        .next_block_id = p.next_block_id,
        .numthreads = .{ .x = 8, .y = 8, .z = 1 },
        .x_param = "",
        .y_param = "",
        .passthrough_body = passthrough,
        .globals_lines = globals,
        .locals = p.locals,
    };
}
