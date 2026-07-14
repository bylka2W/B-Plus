const std = @import("std");
const mir = @import("mir.zig");
const coff = @import("coff.zig");

const TypeKind = enum {
    void, bool,
    i8, i16, i32, i64,
    u8, u16, u32, u64,
    ptr,
    struct_type,
};

const StructTable = std.StringHashMap(StructDef);

const Field = struct {
    name: []const u8,
    type: Type,
    offset: u32,
};

const StructDef = struct {
    name: []const u8,
    fields: []const Field,
    size: u32,
};

const Type = struct {
    kind: TypeKind,
    ptr_elem: TypeKind = .void,
    ptr_elem_struct: []const u8 = "",
    struct_name: []const u8 = "",

    fn fromString(s: []const u8, st: *const StructTable) ?Type {
        if (s.len > 0 and s[0] == '*') {
            const inner = Type.fromString(s[1..], st) orelse return null;
            return .{ .kind = .ptr, .ptr_elem = inner.kind, .ptr_elem_struct = inner.struct_name };
        }
        if (std.mem.eql(u8, s, "int")) return .{ .kind = .i64 };
        if (std.mem.eql(u8, s, "uint")) return .{ .kind = .u64 };
        const k = std.meta.stringToEnum(TypeKind, s) orelse {
            if (st.get(s)) |_| return .{ .kind = .struct_type, .struct_name = s };
            return null;
        };
        return .{ .kind = k };
    }

    fn size(self: Type, st: *const StructTable) u32 {
        return switch (self.kind) {
            .void => 0,
            .ptr => 8,
            .bool, .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32 => 4,
            .i64, .u64 => 8,
            .struct_type => blk: {
                if (st.get(self.struct_name)) |def| break :blk def.size;
                break :blk 0;
            },
        };
    }

    fn isVoid(self: Type) bool {
        return self.kind == .void;
    }

    fn isStruct(self: Type) bool {
        return self.kind == .struct_type;
    }
};

const VarInfo = struct { addr_vreg: u32, type: Type };

const CompilerContext = struct {
    allocator: std.mem.Allocator,
    structs: StructTable,
    source_lines: [][]const u8 = undefined,
    source_path: []const u8 = "",
    err_line_idx: usize = 0,
    err_col: usize = 0,
};

fn reportErr(ctx: *CompilerContext, err_name: []const u8) void {
    const stderr = std.io.getStdErr().writer();
    if (ctx.err_line_idx < ctx.source_lines.len) {
        const line = ctx.source_lines[ctx.err_line_idx];
        const col = if (ctx.err_col < line.len) ctx.err_col else line.len;
        stderr.print("error[{s}]: {s}:{d}:{d}\n", .{ err_name, ctx.source_path, ctx.err_line_idx + 1, col + 1 }) catch {};
        stderr.print("  {d:3} | {s}\n", .{ ctx.err_line_idx + 1, line }) catch {};
        stderr.print("       | ", .{}) catch {};
        for (0..col) |_| stderr.writeAll("-") catch {};
        stderr.writeAll("^\n") catch {};
    } else {
        stderr.print("error[{s}]\n", .{err_name}) catch {};
    }
}

fn findField(def: StructDef, name: []const u8) ?Field {
    for (def.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

const RawField = struct { name: []const u8, type_name: []const u8 };
const RawStruct = struct { name: []const u8, fields: []const RawField };


const Param = struct { name: []const u8, type_name: []const u8 };
const FnDef = struct {
    name: []const u8,
    params: []const Param,
    return_type: []const u8,
    body: []const []const u8,
    body_line_indices: []const usize,
    allocator: std.mem.Allocator,
    fn deinit(self: *FnDef) void {
        self.allocator.free(self.name);
        self.allocator.free(self.params);
        for (self.body) |line| self.allocator.free(line);
        self.allocator.free(self.body);
        self.allocator.free(self.body_line_indices);
    }
};

const Program = struct {
    externs: []const []const u8,
    funcs: []FnDef,
    allocator: std.mem.Allocator,
    fn deinit(self: *Program) void {
        for (self.externs) |e| self.allocator.free(e);
        self.allocator.free(self.externs);
        for (self.funcs) |*f| f.deinit();
        self.allocator.free(self.funcs);
    }
};

fn parse(ctx: *CompilerContext, source: []const u8) !Program {
    var externs = std.ArrayList([]const u8).init(ctx.allocator);
    errdefer { for (externs.items) |e| ctx.allocator.free(e); externs.deinit(); }
    var funcs = std.ArrayList(FnDef).init(ctx.allocator);
    errdefer { for (funcs.items) |*f| { ctx.allocator.free(f.name); ctx.allocator.free(f.params); for (f.body) |l| ctx.allocator.free(l); ctx.allocator.free(f.body); } funcs.deinit(); }

    var lines = std.ArrayList([]const u8).init(ctx.allocator);
    defer lines.deinit();
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        try lines.append(trimmed);
    }

    var raw_structs = std.ArrayList(RawStruct).init(ctx.allocator);
    defer {
        for (raw_structs.items) |rs| { ctx.allocator.free(rs.name); ctx.allocator.free(rs.fields); }
        raw_structs.deinit();
    }

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

        if (std.mem.startsWith(u8, line, "struct ")) {
            const rest = line["struct ".len..];
            const brace_on_same = std.mem.indexOfScalar(u8, rest, '{');
            const name_str = if (brace_on_same) |bp| std.mem.trim(u8, rest[0..bp], " \t") else std.mem.trim(u8, rest, " \t");
            const name = try ctx.allocator.dupe(u8, name_str);
            var fields = std.ArrayList(RawField).init(ctx.allocator);
            errdefer fields.deinit();

            if (brace_on_same == null) {
                i += 1;
                if (i >= lines.items.len or !std.mem.eql(u8, lines.items[i], "{")) return error.ExpectedOpenBrace;
                i += 1;
            } else {
                const after_brace = rest[brace_on_same.? + 1 ..];
                const close_brace = std.mem.indexOfScalar(u8, after_brace, '}');
                if (close_brace) |cb| {
                    const fields_str = std.mem.trim(u8, after_brace[0..cb], " \t");
                    if (fields_str.len > 0) {
                        var field_iter = std.mem.splitScalar(u8, fields_str, ',');
                        while (field_iter.next()) |f| {
                            const ft = std.mem.trim(u8, f, " \t");
                            if (ft.len == 0) continue;
                            const col = std.mem.indexOfScalar(u8, ft, ':') orelse return error.ExpectedColonInParam;
                            const fname = std.mem.trim(u8, ft[0..col], " \t");
                            const ftype_str = std.mem.trim(u8, ft[col + 1 ..], " \t;,");
                            try fields.append(.{ .name = fname, .type_name = ftype_str });
                        }
                    }
                    try raw_structs.append(.{ .name = name, .fields = try fields.toOwnedSlice() });
                    continue;
                }
                i += 1;
            }
            while (i < lines.items.len) {
                const bline = std.mem.trim(u8, lines.items[i], " \t");
                if (std.mem.eql(u8, bline, "}")) break;
                if (bline.len == 0) { i += 1; continue; }
                const colon = std.mem.indexOfScalar(u8, bline, ':') orelse return error.ExpectedColonInParam;
                const fname = std.mem.trim(u8, bline[0..colon], " \t");
                const ftype_str = std.mem.trim(u8, bline[colon + 1 ..], " \t;,");
                try fields.append(.{ .name = fname, .type_name = ftype_str });
                i += 1;
            }
            try raw_structs.append(.{ .name = name, .fields = try fields.toOwnedSlice() });
            continue;
        }

        if (std.mem.startsWith(u8, line, "extern fn ")) {
            const rest = line["extern fn ".len..];
            const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return error.ExpectedParen;
            const fn_name = std.mem.trim(u8, rest[0..paren], " \t");
            try externs.append(try ctx.allocator.dupe(u8, fn_name));
            continue;
        }

        if (std.mem.startsWith(u8, line, "fn ")) {
            const rest = line["fn ".len..];

            const brace_on_same = std.mem.indexOfScalar(u8, rest, '{');
            const sig_end = brace_on_same orelse rest.len;
            const sig = std.mem.trim(u8, rest[0..sig_end], " \t");

            const paren = std.mem.indexOfScalar(u8, sig, '(') orelse return error.ExpectedParen;
            const fn_name = try ctx.allocator.dupe(u8, std.mem.trim(u8, sig[0..paren], " \t"));

            const close_paren = std.mem.indexOfScalar(u8, sig, ')') orelse return error.ExpectedCloseParen;
            const params_str = std.mem.trim(u8, sig[paren + 1 .. close_paren], " \t");

            const after_paren = std.mem.trim(u8, sig[close_paren + 1 ..], " \t");
            var return_type: []const u8 = "";
            if (std.mem.startsWith(u8, after_paren, "->")) {
                return_type = std.mem.trim(u8, after_paren["->".len..], " \t");
            }

            var params = std.ArrayList(Param).init(ctx.allocator);
            errdefer params.deinit();
            if (params_str.len > 0) {
                var param_iter = std.mem.splitScalar(u8, params_str, ',');
                while (param_iter.next()) |p| {
                    const tp = std.mem.trim(u8, p, " \t");
                    const colon = std.mem.indexOfScalar(u8, tp, ':') orelse return error.ExpectedColonInParam;
                    const pname = std.mem.trim(u8, tp[0..colon], " \t");
                    const ptype = std.mem.trim(u8, tp[colon + 1 ..], " \t");
                    try params.append(.{ .name = pname, .type_name = ptype });
                }
            }

            if (brace_on_same == null) {
                i += 1;
                if (i >= lines.items.len or !std.mem.eql(u8, lines.items[i], "{")) {
                    return error.ExpectedOpenBrace;
                }
            }

            var body = std.ArrayList([]const u8).init(ctx.allocator);
            errdefer body.deinit();
            var body_line_indices = std.ArrayList(usize).init(ctx.allocator);
            errdefer body_line_indices.deinit();
            var brace_depth: usize = 1;
            i += 1;
            while (i < lines.items.len and brace_depth > 0) {
                const bline = std.mem.trim(u8, lines.items[i], " \t");
                if (bline.len == 0) { i += 1; continue; }
                if (std.mem.startsWith(u8, bline, "//")) { i += 1; continue; }
                var has_open = false;
                var has_close = false;
                for (bline) |c| {
                    if (c == '{') has_open = true;
                    if (c == '}') has_close = true;
                }
                if (has_open) brace_depth += 1;
                if (has_close) brace_depth -= 1;
                if (brace_depth == 0) break;
                const has_brace = std.mem.indexOfAny(u8, bline, "{}") != null;
                const bline_clean = if (!has_brace) blk: {
                    if (std.mem.lastIndexOfScalar(u8, bline, ';')) |semi_idx| break :blk bline[0..semi_idx];
                    break :blk bline;
                } else bline;
                try body.append(try ctx.allocator.dupe(u8, std.mem.trimRight(u8, bline_clean, " \t")));
                try body_line_indices.append(i);
                i += 1;
            }

            try funcs.append(.{
                .name = fn_name,
                .params = try params.toOwnedSlice(),
                .return_type = return_type,
                .body = try body.toOwnedSlice(),
                .body_line_indices = try body_line_indices.toOwnedSlice(),
                .allocator = ctx.allocator,
            });
            continue;
        }
    }

    for (raw_structs.items) |rs| {
        const key = try ctx.allocator.dupe(u8, rs.name);
        try ctx.structs.put(key, .{ .name = key, .fields = &.{}, .size = 0 });
    }

    for (raw_structs.items) |rs| {
        var fields = std.ArrayList(Field).init(ctx.allocator);
        defer fields.deinit();
        var offset: u32 = 0;
        for (rs.fields) |rf| {
            const ftype = Type.fromString(rf.type_name, &ctx.structs) orelse return error.UnknownType;
            try fields.append(.{ .name = rf.name, .type = ftype, .offset = offset });
            offset += ftype.size(&ctx.structs);
        }
        const key = try ctx.allocator.dupe(u8, rs.name);
        const def = StructDef{
            .name = key,
            .fields = try fields.toOwnedSlice(),
            .size = offset,
        };
        try ctx.structs.put(key, def);
    }

    return Program{
        .externs = try externs.toOwnedSlice(),
        .funcs = try funcs.toOwnedSlice(),
        .allocator = ctx.allocator,
    };
}

const VarScope = std.StringHashMap(VarInfo);

const VarStack = struct {
    scopes: std.ArrayList(VarScope),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) VarStack {
        return .{
            .scopes = std.ArrayList(VarScope).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *VarStack) void {
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit();
    }

    fn push(self: *VarStack) !void {
        try self.scopes.append(VarScope.init(self.allocator));
    }

    fn pop(self: *VarStack) void {
        var scope = self.scopes.pop() orelse return;
        scope.deinit();
    }

    fn get(self: *VarStack, key: []const u8) ?VarInfo {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(key)) |v| return v;
        }
        return null;
    }

    fn put(self: *VarStack, key: []const u8, addr_vreg: u32, typ: Type) !void {
        try self.scopes.items[self.scopes.items.len - 1].put(key, .{ .addr_vreg = addr_vreg, .type = typ });
    }
};

fn compileFn(ctx: *CompilerContext, func_def: FnDef) !mir.MFunction {
    var mfunc = mir.MFunction.init(ctx.allocator, func_def.name);

    var params = try ctx.allocator.alloc(mir.MOperand, func_def.params.len);
    for (func_def.params, 0..) |_, i| params[i] = .{ .vreg = @intCast(i + 1) };
    mfunc.setParams(params);

    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "entry"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    var var_stack = VarStack.init(ctx.allocator);
    defer var_stack.deinit();
    try var_stack.push();

    var next_vreg: u32 = @intCast(func_def.params.len + 1);

    for (func_def.params, 0..) |p, i| {
        const ptype = Type.fromString(p.type_name, &ctx.structs) orelse {
            std.log.err("unknown type '{s}' for param '{s}'", .{ p.type_name, p.name });
            return error.UnknownType;
        };
        const ptr_vreg = next_vreg;
        next_vreg += 1;
        try mfunc.blocks.items[0].instrs.append(.{ .alloca = .{ .size = ptype.size(&ctx.structs), .dst = .{ .vreg = ptr_vreg } } });
        try mfunc.blocks.items[0].instrs.append(.{ .store = .{ .ptr = .{ .vreg = ptr_vreg }, .src = .{ .vreg = @as(u32, @intCast(i + 1)) } } });
        try var_stack.put(p.name, ptr_vreg, ptype);
    }
    var has_explicit_ret = false;
    var last_vreg: ?u32 = null;
    var current_block_idx: usize = 0;
    try compileBlockStmts(ctx, &mfunc, &current_block_idx, &var_stack, &next_vreg, func_def.body, func_def.body_line_indices, 0, func_def.body.len, null, null, &has_explicit_ret, &last_vreg);

    if (!has_explicit_ret) {
        const block = &mfunc.blocks.items[current_block_idx];
        const is_main = std.mem.eql(u8, func_def.name, "main");
        const ret_type = if (func_def.return_type.len > 0) (Type.fromString(func_def.return_type, &ctx.structs) orelse return error.UnknownType) else Type{ .kind = .i64 };
        const is_void = ret_type.isVoid();
        if (is_void) {
            try block.instrs.append(.{ .ret = .{ .val = .{ .imm = 0 }, .is_void = true } });
        } else if (is_main) {
            try block.instrs.append(.{ .ret = .{ .val = .{ .imm = 0 } } });
        } else if (last_vreg) |rv| {
            try block.instrs.append(.{ .ret = .{ .val = .{ .vreg = rv } } });
        } else {
            try block.instrs.append(.{ .ret = .{ .val = .{ .imm = 0 } } });
        }
    }

    return mfunc;
}

fn compileVar(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, line: []const u8) !u32 {
    const rest = std.mem.trimLeft(u8, line["var ".len..], " \t");
    const colon = blk: {
        var depth: usize = 0;
        for (rest, 0..) |c, idx| {
            switch (c) {
                '{' => depth += 1,
                '}' => { if (depth > 0) depth -= 1; },
                '(' => depth += 1,
                ')' => { if (depth > 0) depth -= 1; },
                ':' => if (depth == 0) break :blk idx,
                else => {},
            }
        }
        break :blk null;
    };
    const eq = blk: {
        var depth: usize = 0;
        for (rest, 0..) |c, idx| {
            switch (c) {
                '(' => depth += 1,
                ')' => { if (depth > 0) depth -= 1; },
                '=' => if (depth == 0) break :blk idx,
                else => {},
            }
        }
        break :blk rest.len;
    };

    const name_end = if (colon) |c| c else if (eq < rest.len) eq else rest.len;
    const name = std.mem.trim(u8, rest[0..name_end], " \t");

    const typ = if (colon) |c| blk: {
        const type_str = std.mem.trim(u8, rest[c + 1 .. eq], " \t");
        var t = Type.fromString(type_str, &ctx.structs) orelse return error.UnknownType;
        if (t.kind == .struct_type and t.struct_name.len > 0) {
            t.struct_name = try ctx.allocator.dupe(u8, t.struct_name);
        }
        break :blk t;
    } else if (eq < rest.len) blk: {
        const init_expr = std.mem.trim(u8, rest[eq + 1 ..], " \t");
        if (std.mem.indexOf(u8, init_expr, " {")) |brace| {
            const struct_name = try ctx.allocator.dupe(u8, std.mem.trim(u8, init_expr[0..brace], " \t"));
            if (ctx.structs.get(struct_name)) |_| {
                break :blk Type{ .kind = .struct_type, .struct_name = struct_name };
            }
        }
        break :blk Type{ .kind = .i64 };
    } else Type{ .kind = .i64 };

    const ptr_vreg = next_vreg.*;
    next_vreg.* += 1;
    try block.instrs.append(.{ .alloca = .{ .size = typ.size(&ctx.structs), .dst = .{ .vreg = ptr_vreg } } });

    if (eq < rest.len) {
        const init_expr = std.mem.trim(u8, rest[eq + 1 ..], " \t");
        if (std.mem.indexOf(u8, init_expr, " {")) |brace| {
            const struct_name = std.mem.trim(u8, init_expr[0..brace], " \t");
            const sdef = ctx.structs.get(struct_name) orelse return error.UnknownType;
            var field_start = brace + 2;
            skipSpaces(init_expr, &field_start);
            while (field_start < init_expr.len and init_expr[field_start] != '}') {
                skipSpaces(init_expr, &field_start);
                const fname_start = field_start;
                while (field_start < init_expr.len and init_expr[field_start] != ':') {
                    field_start += 1;
                }
                const fname = std.mem.trim(u8, init_expr[fname_start..field_start], " \t");
                if (field_start >= init_expr.len) return error.UnexpectedToken;
                field_start += 1; // skip ':'
                skipSpaces(init_expr, &field_start);
                const fval_start = field_start;
                var depth: usize = 0;
                while (field_start < init_expr.len) : (field_start += 1) {
                    const c = init_expr[field_start];
                    if (c == '{') {
                        depth += 1;
                    } else if (c == '}') {
                        if (depth == 0) break;
                        depth -= 1;
                    } else if (c == ',') {
                        if (depth == 0) break;
                    }
                }
                const fval_str = std.mem.trim(u8, init_expr[fval_start..field_start], " \t");
                const field = findField(sdef, fname) orelse return error.UnknownVariable;
                const fvreg = try compileExpr(ctx, block, var_stack, next_vreg, fval_str);
                const fp = next_vreg.*;
                next_vreg.* += 1;
                try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = fp }, .src = .{ .vreg = ptr_vreg } } });
                try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = fp }, .src = .{ .imm = field.offset } } });
                try block.instrs.append(.{ .store = .{ .ptr = .{ .vreg = fp }, .src = .{ .vreg = fvreg } } });
                if (field_start < init_expr.len and init_expr[field_start] == ',') {
                    field_start += 1;
                }
            }
        } else {
            const vreg = try compileExpr(ctx, block, var_stack, next_vreg, init_expr);
            try block.instrs.append(.{ .store = .{ .ptr = .{ .vreg = ptr_vreg }, .src = .{ .vreg = vreg } } });
        }
    }

    const name_owned = try ctx.allocator.dupe(u8, name);
    try var_stack.put(name_owned, ptr_vreg, typ);
    return ptr_vreg;
}

fn findAssignment(line: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        switch (line[i]) {
            '(' => depth += 1,
            ')' => { if (depth > 0) depth -= 1; },
            '=' => if (depth == 0 and
                (i + 1 >= line.len or line[i + 1] != '=') and
                (i == 0 or (line[i - 1] != '+' and line[i - 1] != '-' and line[i - 1] != '*'))) return i,
            else => {},
        }
        i += 1;
    }
    return null;
}

fn findCompoundAssign(line: []const u8) ?struct { pos: usize, op: []const u8 } {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        switch (line[i]) {
            '(' => depth += 1,
            ')' => { if (depth > 0) depth -= 1; },
            '+', '-', '*' => {
                if (depth == 0 and i + 1 < line.len and line[i + 1] == '=') {
                    return .{ .pos = i, .op = line[i..i+2] };
                }
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

fn compileBlockStmts(ctx: *CompilerContext, mfunc: *mir.MFunction, block_idx: *usize, var_stack: *VarStack, next_vreg: *u32, body: []const []const u8, body_line_indices: []const usize, start: usize, end: usize, break_target: ?usize, continue_target: ?usize, has_explicit_ret: *bool, last_vreg: *?u32) anyerror!void {
    var i = start;
    while (i < end) : (i += 1) {
        const bline = body[i];
        ctx.err_line_idx = body_line_indices[i];
        ctx.err_col = 0;
        const block = &mfunc.blocks.items[block_idx.*];

        if (std.mem.startsWith(u8, bline, "return ")) {
            const expr = std.mem.trim(u8, bline["return ".len..], " \t;");
            if (expr.len > 0) {
                const rvreg = try compileExpr(ctx, block, var_stack, next_vreg, expr);
                try block.instrs.append(.{ .ret = .{ .val = .{ .vreg = rvreg } } });
            } else {
                try block.instrs.append(.{ .ret = .{ .val = .{ .imm = 0 } } });
            }
            has_explicit_ret.* = true;
        } else if (std.mem.eql(u8, bline, "return")) {
            try block.instrs.append(.{ .ret = .{ .val = .{ .imm = 0 }, .is_void = true } });
            has_explicit_ret.* = true;
        } else if (std.mem.eql(u8, bline, "break")) {
            try block.instrs.append(.{ .jmp = .{ .target = break_target orelse return error.BreakOutsideLoop } });
        } else if (std.mem.eql(u8, bline, "continue")) {
            try block.instrs.append(.{ .jmp = .{ .target = continue_target orelse return error.ContinueOutsideLoop } });
        } else if (std.mem.startsWith(u8, bline, "var ")) {
            if (std.mem.indexOf(u8, bline, " {") != null and std.mem.indexOfScalar(u8, bline, '}') == null) {
                var joined = std.ArrayList(u8).init(ctx.allocator);
                defer joined.deinit();
                try joined.appendSlice(bline);
                i += 1;
                while (i < body.len) {
                    const next_line = body[i];
                    try joined.append(' ');
                    try joined.appendSlice(next_line);
                    if (std.mem.indexOfScalar(u8, next_line, '}') != null) break;
                    i += 1;
                }
                _ = try compileVar(ctx, block, var_stack, next_vreg, joined.items);
            } else {
                _ = try compileVar(ctx, block, var_stack, next_vreg, bline);
            }
        } else if (std.mem.startsWith(u8, bline, "if ")) {
            i = try compileIf(ctx, mfunc, var_stack, next_vreg, body, body_line_indices, i, block_idx.*, break_target, continue_target);
            block_idx.* = mfunc.blocks.items.len - 1;
        } else if (std.mem.startsWith(u8, bline, "while ")) {
            const w = try compileWhile(ctx, mfunc, var_stack, next_vreg, body, body_line_indices, i, block_idx.*);
            i = w.close_idx;
            block_idx.* = w.exit_idx;
        } else if (std.mem.startsWith(u8, bline, "for ")) {
            const f = try compileFor(ctx, mfunc, var_stack, next_vreg, body, body_line_indices, i, block_idx.*);
            i = f.close_idx;
            block_idx.* = f.exit_idx;
        } else if (std.mem.eql(u8, bline, "{")) {
            try var_stack.push();
        } else if (std.mem.eql(u8, bline, "}")) {
            var_stack.pop();
        } else if (findAssignment(bline)) |ep| {
            const lhs = std.mem.trim(u8, bline[0..ep], " \t");
            const expr = std.mem.trim(u8, bline[ep + 1 ..], " \t");
            const rvreg = try compileExpr(ctx, block, var_stack, next_vreg, expr);
            if (std.mem.startsWith(u8, lhs, "*")) {
                const ptr_expr = std.mem.trim(u8, lhs[1..], " \t");
                const pvreg = try compileExpr(ctx, block, var_stack, next_vreg, ptr_expr);
                try block.instrs.append(.{ .store = .{ .ptr = .{ .vreg = pvreg }, .src = .{ .vreg = rvreg } } });
            } else if (std.mem.indexOfScalar(u8, lhs, '.')) |dot| {
                const base_name = std.mem.trim(u8, lhs[0..dot], " \t");
                const field_name = std.mem.trim(u8, lhs[dot + 1 ..], " \t");
                const vi = var_stack.get(base_name) orelse return error.UnknownVariable;
                if (!vi.type.isStruct()) return error.TypeMismatch;
                const sdef = ctx.structs.get(vi.type.struct_name) orelse return error.UnknownType;
                const field = findField(sdef, field_name) orelse return error.UnknownVariable;
                const field_ptr = next_vreg.*;
                next_vreg.* += 1;
                try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = field_ptr }, .src = .{ .vreg = vi.addr_vreg } } });
                try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = field_ptr }, .src = .{ .imm = field.offset } } });
                try block.instrs.append(.{ .store = .{ .ptr = .{ .vreg = field_ptr }, .src = .{ .vreg = rvreg } } });
            } else {
                const vi = var_stack.get(lhs) orelse return error.UnknownVariable;
                try block.instrs.append(.{ .store = .{ .ptr = .{ .vreg = vi.addr_vreg }, .src = .{ .vreg = rvreg } } });
            }
        } else if (findCompoundAssign(bline)) |ca| {
            const lhs = std.mem.trim(u8, bline[0..ca.pos], " \t");
            const expr = std.mem.trim(u8, bline[ca.pos + 2 ..], " \t");
            const vi = var_stack.get(lhs) orelse return error.UnknownVariable;
            const lvreg = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .load = .{ .dst = .{ .vreg = lvreg }, .ptr = .{ .vreg = vi.addr_vreg } } });
            const rvreg = try compileExpr(ctx, block, var_stack, next_vreg, expr);
            if (std.mem.eql(u8, ca.op, "+=")) {
                try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = lvreg }, .src = .{ .vreg = rvreg } } });
            } else if (std.mem.eql(u8, ca.op, "-=")) {
                try block.instrs.append(.{ .sub = .{ .dst = .{ .vreg = lvreg }, .src = .{ .vreg = rvreg } } });
            } else if (std.mem.eql(u8, ca.op, "*=")) {
                try block.instrs.append(.{ .imul = .{ .dst = .{ .vreg = lvreg }, .src = .{ .vreg = rvreg } } });
            } else {
                return error.UnexpectedToken;
            }
            try block.instrs.append(.{ .store = .{ .ptr = .{ .vreg = vi.addr_vreg }, .src = .{ .vreg = lvreg } } });
        } else {
            last_vreg.* = try compileExpr(ctx, block, var_stack, next_vreg, bline);
        }
    }
}

fn compileIf(ctx: *CompilerContext, mfunc: *mir.MFunction, var_stack: *VarStack, next_vreg: *u32, body: []const []const u8, body_line_indices: []const usize, start_idx: usize, current_idx: usize, break_target: ?usize, continue_target: ?usize) !usize {
    const line = body[start_idx];

    const cond_str = if (std.mem.indexOfScalar(u8, line, '(')) |paren_open| blk: {
        const paren_close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return error.ExpectedCloseParen;
        break :blk std.mem.trim(u8, line[paren_open + 1 .. paren_close], " \t");
    } else blk: {
        const keyword_end = "if ".len;
        const brace = std.mem.indexOfScalar(u8, line, '{') orelse {
            if (start_idx + 1 >= body.len) return error.ExpectedOpenBrace;
            const next_line = body[start_idx + 1];
            if (!std.mem.eql(u8, next_line, "{")) return error.ExpectedOpenBrace;
            break :blk std.mem.trim(u8, line[keyword_end..], " \t");
        };
        break :blk std.mem.trim(u8, line[keyword_end..brace], " \t");
    };

    const same_line_brace = std.mem.indexOfScalar(u8, line, '{');
    var i = start_idx + 1;
    if (same_line_brace == null) {
        if (i >= body.len) return error.ExpectedOpenBrace;
        i += 1;
    }

    const then_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "then"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    {
        const cc = try compileCond(ctx, &mfunc.blocks.items[current_idx], var_stack, next_vreg, cond_str);
        try mfunc.blocks.items[current_idx].instrs.append(.{ .jcc = .{ .cc = cc, .target = then_idx } });
    }

    var brace_depth: usize = 1;
    var has_else = false;
    const then_start = i;
    var then_end: usize = 0;
    var else_start: usize = 0;
    var else_end: usize = 0;
    var close_idx: usize = 0;

    while (i < body.len and brace_depth > 0) : (i += 1) {
        const bline = body[i];
        var has_open = false;
        var has_close = false;
        for (bline) |c| {
            if (c == '{') has_open = true;
            if (c == '}') has_close = true;
        }
        if (has_close) brace_depth -= 1;

        if (brace_depth == 0) {
            if (!has_else and has_open and std.mem.indexOf(u8, bline, "else") != null) {
                has_else = true;
                then_end = i;
                brace_depth = 1;
                else_start = i + 1;
                continue;
            }
            close_idx = i;
            if (!has_else) {
                then_end = close_idx;
            } else {
                else_end = close_idx;
            }
            if (!has_else and i + 1 < body.len and std.mem.startsWith(u8, body[i + 1], "else")) {
                has_else = true;
                brace_depth = 1;
                else_start = i + 2;
                i += 1;
                continue;
            }
            break;
        }

        if (has_open) brace_depth += 1;
        if (has_open or has_close) continue;
    }

    const else_idx = if (has_else) blk: {
        const idx = mfunc.blocks.items.len;
        try mfunc.blocks.append(.{
            .label = try ctx.allocator.dupe(u8, "else"),
            .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
        });
        break :blk idx;
    } else null;

    const merge_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "merge"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    try mfunc.blocks.items[current_idx].instrs.append(.{ .jmp = .{ .target = else_idx orelse merge_idx } });

    {
        var body_block_idx = then_idx;
        {
            var dummy_ret = false;
            var dummy_last: ?u32 = null;
            try compileBlockStmts(ctx, mfunc, &body_block_idx, var_stack, next_vreg, body, body_line_indices, then_start, then_end, break_target, continue_target, &dummy_ret, &dummy_last);
        }
    }
    try mfunc.blocks.items[then_idx].instrs.append(.{ .jmp = .{ .target = merge_idx } });

    if (has_else) {
        {
            var body_block_idx = else_idx.?;
            var dummy_ret = false;
            var dummy_last: ?u32 = null;
            try compileBlockStmts(ctx, mfunc, &body_block_idx, var_stack, next_vreg, body, body_line_indices, else_start, else_end, break_target, continue_target, &dummy_ret, &dummy_last);
        }
        try mfunc.blocks.items[else_idx.?].instrs.append(.{ .jmp = .{ .target = merge_idx } });
    }

    return close_idx;
}

fn compileWhile(ctx: *CompilerContext, mfunc: *mir.MFunction, var_stack: *VarStack, next_vreg: *u32, body: []const []const u8, body_line_indices: []const usize, start_idx: usize, before_header_idx: usize) !struct { close_idx: usize, exit_idx: usize } {
    const line = body[start_idx];

    const cond_str = if (std.mem.indexOfScalar(u8, line, '(')) |paren_open| blk: {
        const paren_close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return error.ExpectedCloseParen;
        break :blk std.mem.trim(u8, line[paren_open + 1 .. paren_close], " \t");
    } else blk: {
        const keyword_end = "while ".len;
        const brace = std.mem.indexOfScalar(u8, line, '{') orelse {
            if (start_idx + 1 >= body.len) return error.ExpectedOpenBrace;
            const next_line = body[start_idx + 1];
            if (!std.mem.eql(u8, next_line, "{")) return error.ExpectedOpenBrace;
            break :blk std.mem.trim(u8, line[keyword_end..], " \t");
        };
        break :blk std.mem.trim(u8, line[keyword_end..brace], " \t");
    };

    const same_line_brace = std.mem.indexOfScalar(u8, line, '{');
    var i = start_idx + 1;
    if (same_line_brace == null) {
        if (i >= body.len) return error.ExpectedOpenBrace;
        i += 1;
    }

    const header_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "loop_header"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    const body_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "loop_body"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    var brace_depth: usize = 1;
    const body_start = i;

    while (i < body.len and brace_depth > 0) {
        const bline = body[i];
        var has_open = false;
        var has_close = false;
        for (bline) |c| {
            if (c == '{') has_open = true;
            if (c == '}') has_close = true;
        }
        if (has_close) brace_depth -= 1;
        if (brace_depth == 0) break;
        if (has_open) brace_depth += 1;
        if (has_open or has_close) { i += 1; continue; }
        i += 1;
    }

    const body_end = i;
    const exit_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "loop_exit"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    try mfunc.blocks.items[before_header_idx].instrs.append(.{ .jmp = .{ .target = header_idx } });

    {
        const cc = try compileCond(ctx, &mfunc.blocks.items[header_idx], var_stack, next_vreg, cond_str);
        try mfunc.blocks.items[header_idx].instrs.append(.{ .jcc = .{ .cc = cc, .target = body_idx } });
        try mfunc.blocks.items[header_idx].instrs.append(.{ .jmp = .{ .target = exit_idx } });
    }

    {
        var body_block_idx = body_idx;
        var dummy_ret = false;
        var dummy_last: ?u32 = null;
        try compileBlockStmts(ctx, mfunc, &body_block_idx, var_stack, next_vreg, body, body_line_indices, body_start, body_end, exit_idx, header_idx, &dummy_ret, &dummy_last);
        try mfunc.blocks.items[body_block_idx].instrs.append(.{ .jmp = .{ .target = header_idx } });
    }

    return .{ .close_idx = i, .exit_idx = exit_idx };
}

fn compileFor(ctx: *CompilerContext, mfunc: *mir.MFunction, var_stack: *VarStack, next_vreg: *u32, body: []const []const u8, body_line_indices: []const usize, start_idx: usize, before_header_idx: usize) !struct { close_idx: usize, exit_idx: usize } {
    const line = body[start_idx];

    const after_for = line["for ".len..];
    const in_pos = std.mem.indexOf(u8, after_for, " in ") orelse return error.ExpectedIn;
    const var_name = std.mem.trim(u8, after_for[0..in_pos], " \t");

    const range_str = std.mem.trim(u8, after_for[in_pos + 4 ..], " \t");
    const dotdot = std.mem.indexOf(u8, range_str, "..") orelse return error.ExpectedRange;
    const start_str = std.mem.trim(u8, range_str[0..dotdot], " \t");
    const end_str = std.mem.trim(u8, range_str[dotdot + 2 ..], " \t");

    const same_line_brace = std.mem.indexOfScalar(u8, line, '{');
    var i = start_idx + 1;
    if (same_line_brace == null) {
        if (i >= body.len) return error.ExpectedOpenBrace;
        i += 1;
    }

    const header_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "for_header"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    const body_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "for_body"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    var brace_depth: usize = 1;
    const body_start = i;

    while (i < body.len and brace_depth > 0) {
        const bline = body[i];
        var has_open = false;
        var has_close = false;
        for (bline) |c| {
            if (c == '{') has_open = true;
            if (c == '}') has_close = true;
        }
        if (has_close) brace_depth -= 1;
        if (brace_depth == 0) break;
        if (has_open) brace_depth += 1;
        if (has_open or has_close) { i += 1; continue; }
        i += 1;
    }

    const body_end = i;
    const exit_idx = mfunc.blocks.items.len;
    try mfunc.blocks.append(.{
        .label = try ctx.allocator.dupe(u8, "for_exit"),
        .instrs = std.ArrayList(mir.MInst).init(ctx.allocator),
    });

    const first_block = &mfunc.blocks.items[before_header_idx];

    const start_vreg = next_vreg.*;
    next_vreg.* += 1;
    try first_block.instrs.append(.{ .alloca = .{ .size = 8, .dst = .{ .vreg = start_vreg } } });
    const start_val = try compileExpr(ctx, first_block, var_stack, next_vreg, start_str);
    try first_block.instrs.append(.{ .store = .{ .ptr = .{ .vreg = start_vreg }, .src = .{ .vreg = start_val } } });
    try var_stack.put(var_name, start_vreg, Type{ .kind = .i64 });

    try first_block.instrs.append(.{ .jmp = .{ .target = header_idx } });

    {
        const header_block = &mfunc.blocks.items[header_idx];
        const ivreg = next_vreg.*;
        next_vreg.* += 1;
        try header_block.instrs.append(.{ .load = .{ .dst = .{ .vreg = ivreg }, .ptr = .{ .vreg = start_vreg } } });
        const end_vreg = try compileExpr(ctx, header_block, var_stack, next_vreg, end_str);
        try header_block.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = ivreg }, .b = .{ .vreg = end_vreg } } });
        try header_block.instrs.append(.{ .jcc = .{ .cc = .lt, .target = body_idx } });
        try header_block.instrs.append(.{ .jmp = .{ .target = exit_idx } });
    }

    {
        var body_block_idx = body_idx;
        var dummy_ret = false;
        var dummy_last: ?u32 = null;
        try compileBlockStmts(ctx, mfunc, &body_block_idx, var_stack, next_vreg, body, body_line_indices, body_start, body_end, exit_idx, header_idx, &dummy_ret, &dummy_last);

        const ivreg = next_vreg.*;
        next_vreg.* += 1;
        try mfunc.blocks.items[body_block_idx].instrs.append(.{ .load = .{ .dst = .{ .vreg = ivreg }, .ptr = .{ .vreg = start_vreg } } });
        const one_vreg = next_vreg.*;
        next_vreg.* += 1;
        try mfunc.blocks.items[body_block_idx].instrs.append(.{ .mov = .{ .dst = .{ .vreg = one_vreg }, .src = .{ .imm = 1 } } });
        try mfunc.blocks.items[body_block_idx].instrs.append(.{ .add = .{ .dst = .{ .vreg = ivreg }, .src = .{ .vreg = one_vreg } } });
        try mfunc.blocks.items[body_block_idx].instrs.append(.{ .store = .{ .ptr = .{ .vreg = start_vreg }, .src = .{ .vreg = ivreg } } });

        try mfunc.blocks.items[body_block_idx].instrs.append(.{ .jmp = .{ .target = header_idx } });
    }

    return .{ .close_idx = i, .exit_idx = exit_idx };
}

fn compileCond(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, cond_str: []const u8) !mir.CondCode {
    const ops = [_]struct { op: []const u8, cc: mir.CondCode }{ .{ .op = ">=", .cc = .ge }, .{ .op = "<=", .cc = .le }, .{ .op = "==", .cc = .eq }, .{ .op = "!=", .cc = .ne }, .{ .op = ">", .cc = .gt }, .{ .op = "<", .cc = .lt } };
    for (&ops) |entry| {
        if (std.mem.indexOf(u8, cond_str, entry.op)) |pos| {
            const left = std.mem.trim(u8, cond_str[0..pos], " \t");
            const right = std.mem.trim(u8, cond_str[pos + entry.op.len ..], " \t");
            const lvreg = try compileExpr(ctx, block, var_stack, next_vreg, left);
            const rvreg = try compileExpr(ctx, block, var_stack, next_vreg, right);
            try block.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = lvreg }, .b = .{ .vreg = rvreg } } });
            return entry.cc;
        }
    }
    return error.InvalidCondition;
}

const ParseError = error{
    OutOfMemory,
    ExpectedCloseParen,
    ExpectedComma,
    TooManyArgs,
    UnknownVariable,
    UnexpectedToken,
    UnexpectedEnd,
    UnknownType,
    TypeMismatch,
};

const ExprResult = struct { vreg: u32, val: ?i64 };

fn skipSpaces(expr: []const u8, pos: *usize) void {
    while (pos.* < expr.len and (expr[pos.*] == ' ' or expr[pos.*] == '\t')) {
        pos.* += 1;
    }
}

fn parsePrimary(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    skipSpaces(expr, pos);
    if (pos.* >= expr.len) return error.UnexpectedEnd;

    if (expr[pos.*] == '(') {
        pos.* += 1;
        const inner = try parseExpr(ctx, block, var_stack, next_vreg, expr, pos);
        skipSpaces(expr, pos);
        if (pos.* >= expr.len or expr[pos.*] != ')') return error.ExpectedCloseParen;
        pos.* += 1;
        return inner;
    }

    if (expr[pos.*] == '&') {
        pos.* += 1;
        skipSpaces(expr, pos);
        const name_start = pos.*;
        while (pos.* < expr.len and (std.ascii.isAlphanumeric(expr[pos.*]) or expr[pos.*] == '_')) {
            pos.* += 1;
        }
        if (pos.* > name_start) {
            const name = expr[name_start..pos.*];
            const vi = var_stack.get(name) orelse return error.UnknownVariable;
            skipSpaces(expr, pos);
            if (pos.* < expr.len and expr[pos.*] == '.') {
                pos.* += 1;
                const field_start = pos.*;
                while (pos.* < expr.len and (std.ascii.isAlphanumeric(expr[pos.*]) or expr[pos.*] == '_')) {
                    pos.* += 1;
                }
                const field_name = expr[field_start..pos.*];
                if (!vi.type.isStruct()) return error.TypeMismatch;
                const sdef = ctx.structs.get(vi.type.struct_name) orelse return error.UnknownType;
                const field = findField(sdef, field_name) orelse return error.UnknownVariable;
                const field_ptr = next_vreg.*;
                next_vreg.* += 1;
                try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = field_ptr }, .src = .{ .vreg = vi.addr_vreg } } });
                try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = field_ptr }, .src = .{ .imm = field.offset } } });
                return .{ .vreg = field_ptr, .val = null };
            }
            return .{ .vreg = vi.addr_vreg, .val = null };
        }
        return error.UnexpectedToken;
    }

    const start = pos.*;
    while (pos.* < expr.len and (std.ascii.isAlphanumeric(expr[pos.*]) or expr[pos.*] == '_')) {
        pos.* += 1;
    }
    if (pos.* > start) {
        const name = expr[start..pos.*];
        if (std.ascii.isDigit(name[0])) {
            const val = std.fmt.parseInt(i64, name, 10) catch return error.UnexpectedToken;
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .imm = val } } });
            return .{ .vreg = dst, .val = val };
        }
        skipSpaces(expr, pos);
        if (pos.* < expr.len and expr[pos.*] == '(') {
            pos.* += 1;
            var arg_vregs: [4]mir.MOperand = .{ .{ .imm = 0 }, .{ .imm = 0 }, .{ .imm = 0 }, .{ .imm = 0 } };
            var arg_count: u32 = 0;
            skipSpaces(expr, pos);
            if (pos.* < expr.len and expr[pos.*] != ')') {
                while (true) {
                    if (arg_count >= 4) return error.TooManyArgs;
                    const aresult = try parseExpr(ctx, block, var_stack, next_vreg, expr, pos);
                    arg_vregs[arg_count] = .{ .vreg = aresult.vreg };
                    arg_count += 1;
                    skipSpaces(expr, pos);
                    if (pos.* >= expr.len) return error.ExpectedCloseParen;
                    if (expr[pos.*] == ')') break;
                    if (expr[pos.*] != ',') return error.ExpectedComma;
                    pos.* += 1;
                    skipSpaces(expr, pos);
                }
            }
            if (pos.* >= expr.len or expr[pos.*] != ')') return error.ExpectedCloseParen;
            pos.* += 1;
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{
                .call = .{
                    .name = try ctx.allocator.dupe(u8, name),
                    .args = arg_vregs,
                    .arg_count = arg_count,
                    .dst = .{ .vreg = dst },
                },
            });
            return .{ .vreg = dst, .val = null };
        }
        const vi = var_stack.get(name) orelse return error.UnknownVariable;
        skipSpaces(expr, pos);
        if (pos.* < expr.len and expr[pos.*] == '.') {
            pos.* += 1;
            const field_start = pos.*;
            while (pos.* < expr.len and (std.ascii.isAlphanumeric(expr[pos.*]) or expr[pos.*] == '_')) {
                pos.* += 1;
            }
            const field_name = expr[field_start..pos.*];
            if (!vi.type.isStruct()) return error.TypeMismatch;
            const sdef = ctx.structs.get(vi.type.struct_name) orelse return error.UnknownType;
            const field = findField(sdef, field_name) orelse return error.UnknownVariable;
            const field_ptr = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = field_ptr }, .src = .{ .vreg = vi.addr_vreg } } });
            try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = field_ptr }, .src = .{ .imm = field.offset } } });
            const load_dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .load = .{ .dst = .{ .vreg = load_dst }, .ptr = .{ .vreg = field_ptr } } });
            return .{ .vreg = load_dst, .val = null };
        }
        const load_dst = next_vreg.*;
        next_vreg.* += 1;
        try block.instrs.append(.{ .load = .{ .dst = .{ .vreg = load_dst }, .ptr = .{ .vreg = vi.addr_vreg } } });
        return .{ .vreg = load_dst, .val = null };
    }

    const num_start = pos.*;
    while (pos.* < expr.len and std.ascii.isDigit(expr[pos.*])) {
        pos.* += 1;
    }
    if (pos.* > num_start) {
        const val = std.fmt.parseInt(i64, expr[num_start..pos.*], 10) catch return error.UnexpectedToken;
        const dst = next_vreg.*;
        next_vreg.* += 1;
        try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .imm = val } } });
        return .{ .vreg = dst, .val = val };
    }

    return error.UnexpectedToken;
}

fn parseUnary(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    skipSpaces(expr, pos);
    if (pos.* < expr.len and expr[pos.*] == '*') {
        pos.* += 1;
        const inner = try parseUnary(ctx, block, var_stack, next_vreg, expr, pos);
        const dst = next_vreg.*;
        next_vreg.* += 1;
        try block.instrs.append(.{ .load = .{ .dst = .{ .vreg = dst }, .ptr = .{ .vreg = inner.vreg } } });
        return .{ .vreg = dst, .val = null };
    }
    return parsePrimary(ctx, block, var_stack, next_vreg, expr, pos);
}

fn parseMulDiv(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    var left = try parseUnary(ctx, block, var_stack, next_vreg, expr, pos);
    while (true) {
        skipSpaces(expr, pos);
        if (pos.* >= expr.len) break;
        const op = expr[pos.*];
        if (op != '*' and op != '/') break;
        pos.* += 1;
        const right = try parseUnary(ctx, block, var_stack, next_vreg, expr, pos);
        if (left.val != null and right.val != null) {
            const folded = if (op == '*') left.val.? *% right.val.? else @divTrunc(left.val.?, right.val.?);
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .imm = folded } } });
            left = .{ .vreg = dst, .val = folded };
        } else {
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = left.vreg } } });
            if (op == '*') {
                try block.instrs.append(.{ .imul = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = right.vreg } } });
            } else {
                try block.instrs.append(.{ .idiv = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = right.vreg } } });
            }
            left = .{ .vreg = dst, .val = null };
        }
    }
    return left;
}

fn parseAddSub(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    var left = try parseMulDiv(ctx, block, var_stack, next_vreg, expr, pos);
    while (true) {
        skipSpaces(expr, pos);
        if (pos.* >= expr.len) break;
        const op = expr[pos.*];
        if (op != '+' and op != '-') break;
        pos.* += 1;
        const right = try parseMulDiv(ctx, block, var_stack, next_vreg, expr, pos);
        if (left.val != null and right.val != null) {
            const folded = if (op == '+') left.val.? +% right.val.? else left.val.? -% right.val.?;
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .imm = folded } } });
            left = .{ .vreg = dst, .val = folded };
        } else {
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = left.vreg } } });
            if (op == '+') {
                try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = right.vreg } } });
            } else {
                try block.instrs.append(.{ .sub = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = right.vreg } } });
            }
            left = .{ .vreg = dst, .val = null };
        }
    }
    return left;
}

fn parseComparison(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    var left = try parseAddSub(ctx, block, var_stack, next_vreg, expr, pos);
    while (true) {
        skipSpaces(expr, pos);
        if (pos.* >= expr.len) break;
        var op: []const u8 = undefined;
        if (pos.* + 1 < expr.len) {
            const two = expr[pos.*..pos.*+2];
            if (std.mem.eql(u8, two, ">=") or std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "!=")) {
                op = two;
                pos.* += 2;
            } else if (expr[pos.*] == '>' or expr[pos.*] == '<') {
                op = expr[pos.*..pos.*+1];
                pos.* += 1;
            } else break;
        } else if (expr[pos.*] == '>' or expr[pos.*] == '<') {
            op = expr[pos.*..pos.*+1];
            pos.* += 1;
        } else break;

        const right = try parseAddSub(ctx, block, var_stack, next_vreg, expr, pos);
        if (left.val != null and right.val != null) {
            const cmp = struct {
                fn eval(l: i64, r: i64, cc: mir.CondCode) bool {
                    return switch (cc) {
                        .ge => l >= r, .le => l <= r, .eq => l == r,
                        .ne => l != r, .gt => l > r, .lt => l < r,
                    };
                }
            }.eval(left.val.?, right.val.?, if (std.mem.eql(u8, op, ">=")) .ge else if (std.mem.eql(u8, op, "<=")) .le else if (std.mem.eql(u8, op, "==")) .eq else if (std.mem.eql(u8, op, "!=")) .ne else if (std.mem.eql(u8, op, ">")) .gt else .lt);
            const folded: i64 = if (cmp) 1 else 0;
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .imm = folded } } });
            left = .{ .vreg = dst, .val = folded };
        } else {
            const dst = next_vreg.*;
            next_vreg.* += 1;
            const cc: mir.CondCode = if (std.mem.eql(u8, op, ">=")) .ge else if (std.mem.eql(u8, op, "<=")) .le else if (std.mem.eql(u8, op, "==")) .eq else if (std.mem.eql(u8, op, "!=")) .ne else if (std.mem.eql(u8, op, ">")) .gt else .lt;
            try block.instrs.append(.{ .cmp = .{ .cc = cc, .dst = .{ .vreg = dst }, .a = .{ .vreg = left.vreg }, .b = .{ .vreg = right.vreg } } });
            left = .{ .vreg = dst, .val = null };
        }
    }
    return left;
}

fn parseLogicalAnd(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    var left = try parseComparison(ctx, block, var_stack, next_vreg, expr, pos);
    while (true) {
        skipSpaces(expr, pos);
        if (pos.* + 1 >= expr.len or expr[pos.*] != '&' or expr[pos.* + 1] != '&') break;
        pos.* += 2;
        const right = try parseComparison(ctx, block, var_stack, next_vreg, expr, pos);
        if (left.val != null and right.val != null) {
            const folded: i64 = if (left.val.? != 0 and right.val.? != 0) 1 else 0;
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .imm = folded } } });
            left = .{ .vreg = dst, .val = folded };
        } else {
            const t1 = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .cmp = .{ .cc = .ne, .dst = .{ .vreg = t1 }, .a = .{ .vreg = left.vreg }, .b = .{ .imm = 0 } } });
            const t2 = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .cmp = .{ .cc = .ne, .dst = .{ .vreg = t2 }, .a = .{ .vreg = right.vreg }, .b = .{ .imm = 0 } } });
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = t1 } } });
            try block.instrs.append(.{ .imul = .{ .dst = .{ .vreg = dst }, .src = .{ .vreg = t2 } } });
            left = .{ .vreg = dst, .val = null };
        }
    }
    return left;
}

fn parseLogicalOr(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    var left = try parseLogicalAnd(ctx, block, var_stack, next_vreg, expr, pos);
    while (true) {
        skipSpaces(expr, pos);
        if (pos.* + 1 >= expr.len or expr[pos.*] != '|' or expr[pos.* + 1] != '|') break;
        pos.* += 2;
        const right = try parseLogicalAnd(ctx, block, var_stack, next_vreg, expr, pos);
        if (left.val != null and right.val != null) {
            const folded: i64 = if (left.val.? != 0 or right.val.? != 0) 1 else 0;
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = dst }, .src = .{ .imm = folded } } });
            left = .{ .vreg = dst, .val = folded };
        } else {
            const t1 = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .cmp = .{ .cc = .ne, .dst = .{ .vreg = t1 }, .a = .{ .vreg = left.vreg }, .b = .{ .imm = 0 } } });
            const t2 = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .cmp = .{ .cc = .ne, .dst = .{ .vreg = t2 }, .a = .{ .vreg = right.vreg }, .b = .{ .imm = 0 } } });
            const sum = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = sum }, .src = .{ .vreg = t1 } } });
            try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = sum }, .src = .{ .vreg = t2 } } });
            const dst = next_vreg.*;
            next_vreg.* += 1;
            try block.instrs.append(.{ .cmp = .{ .cc = .ne, .dst = .{ .vreg = dst }, .a = .{ .vreg = sum }, .b = .{ .imm = 0 } } });
            left = .{ .vreg = dst, .val = null };
        }
    }
    return left;
}

fn parseExpr(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8, pos: *usize) ParseError!ExprResult {
    return parseLogicalOr(ctx, block, var_stack, next_vreg, expr, pos);
}

fn compileExpr(ctx: *CompilerContext, block: *mir.MBlock, var_stack: *VarStack, next_vreg: *u32, expr: []const u8) !u32 {
    var pos: usize = 0;
    const result = try parseExpr(ctx, block, var_stack, next_vreg, expr, &pos);
    return result.vreg;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = CompilerContext{
        .allocator = allocator,
        .structs = StructTable.init(allocator),
    };

    const args = try std.process.argsAlloc(allocator);

    if (args.len < 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: bplus build <input.bp> [-o <output.exe>]\n");
        try stderr.writeAll("       bplus run   <input.bp>\n");
        std.process.exit(1);
    }

    const command = args[1];
    const input_path = args[2];
    var output_path: ?[]const u8 = null;
    if (args.len >= 4 and std.mem.eql(u8, args[3], "-o") and args.len >= 5) {
        output_path = args[4];
    }

    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(u32));

    var source_lines = std.ArrayList([]const u8).init(allocator);
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |l| {
        try source_lines.append(l);
    }
    ctx.source_lines = source_lines.items;
    ctx.source_path = input_path;

    const prog = if (parse(&ctx, source)) |p| p else |err| {
        reportErr(&ctx, @errorName(err));
        std.process.exit(1);
    };

    var mfuncs = std.ArrayList(mir.MFunction).init(allocator);
    for (prog.funcs) |fd| {
        const mf = if (compileFn(&ctx, fd)) |f| f else |err| {
            reportErr(&ctx, @errorName(err));
            std.process.exit(1);
        };
        try mfuncs.append(mf);
    }

    const coff_result = try coff.emitCoff(mfuncs.items);

    const tmp_dir_path = "C:\\Users\\Local\\AppData\\Local\\Temp\\opencode";
    const tmp_dir = try std.fs.openDirAbsolute(tmp_dir_path, .{});

    const zig_exe = "C:\\tools\\zig\\zig-windows-x86_64-0.14.0\\zig.exe";

    const obj_name = "bplus_output.obj";
    _ = tmp_dir.deleteFile(obj_name) catch {};

    try tmp_dir.writeFile(.{ .sub_path = obj_name, .data = coff_result.bytes.items });
    const obj_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, obj_name });

    const final_path = blk: {
        if (output_path) |p| break :blk try allocator.dupe(u8, p);
        const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
        const base = input_path[0..ext_idx];
        const last_sep = std.mem.lastIndexOfAny(u8, base, "\\/") orelse 0;
        const fname = if (last_sep > 0) base[last_sep + 1 ..] else base;
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        const rel = try std.fmt.allocPrint(allocator, "{s}.exe", .{fname});
        const abs = try std.fs.path.join(allocator, &.{ cwd, rel });
        break :blk abs;
    };

    const exe_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "bplus_output.exe" });

    {
        var argv = std.ArrayList([]const u8).init(allocator);
        try argv.append(zig_exe);
        try argv.append("build-exe");
        try argv.append(obj_path);
        try argv.append("C:\\B-Plus\\zig\\src\\bplusrt.obj");
        try argv.append("-fentry=main");
        try argv.append("--subsystem");
        try argv.append("console");
        try argv.append("-OReleaseSmall");
        try argv.append("-lkernel32");
        const emit_flag = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{exe_path});
        try argv.append(emit_flag);
        try argv.append("--cache-dir");
        try argv.append(tmp_dir_path);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const stderr_data = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 16);
        const term = try child.wait();
        if (term.Exited != 0) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("link failed (exit {d}):\n{s}\n", .{ term.Exited, std.mem.trimRight(u8, stderr_data, " \r\n") });
            std.process.exit(1);
        }
    }

    try std.fs.copyFileAbsolute(exe_path, final_path, .{});

    if (std.mem.eql(u8, command, "run")) {
        var child = std.process.Child.init(&[_][]const u8{final_path}, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = try child.spawnAndWait();
    }
}
