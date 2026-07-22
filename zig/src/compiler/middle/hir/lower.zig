const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../frontend/ast.zig");
const sema_mod = @import("../../frontend/sema/sema.zig");
const hir = @import("node.zig");
const types = @import("types.zig");
const TypeId = types.TypeId;

const LowerError = error{ ParseError, TypeNotFound, OutOfMemory };

pub const SemaContext = struct {
    result: ?*const sema_mod.SemaResult,

    pub fn empty() SemaContext {
        return .{ .result = null };
    }

    pub fn fromResult(result: *const sema_mod.SemaResult) SemaContext {
        return .{ .result = result };
    }

    pub fn resolveType(self: SemaContext, name: []const u8) TypeId {
        if (self.result) |sr| {
            for (sr.typed_vars.items) |v| {
                if (v.type_name) |tn| {
                    if (std.mem.eql(u8, tn, name)) return v.type_id;
                }
            }
        }
        return TypeId.fromName(name);
    }

    pub fn lookupVarType(self: SemaContext, name: []const u8) ?TypeId {
        if (self.result) |sr| {
            return sr.lookupVarType(name);
        }
        return null;
    }
};

pub fn lowerProgram(allocator: Allocator, program: *const ast.ProgramNode, sema_ctx: SemaContext) !hir.HirModule {
    var module = hir.HirModule.init(allocator);
    errdefer module.deinit();

    for (program.func_defs.items) |func| {
        const hir_func = try lowerFunction(allocator, func, sema_ctx);
        try module.functions.append(hir_func);
    }
    for (program.states.items) |state| {
        const hir_state = try lowerState(allocator, state, sema_ctx);
        try module.states.append(hir_state);
    }
    return module;
}

fn lowerFunction(allocator: Allocator, func: ast.EntryDecl, sema_ctx: SemaContext) !hir.HirFunction {
    var params = std.ArrayList(types.FuncParam).init(allocator);
    for (func.params.items) |p| {
        const resolved_ty = sema_ctx.resolveType(p.type_name);
        try params.append(.{
            .name = try allocator.dupe(u8, p.name),
            .ty = if (resolved_ty != .invalid) resolved_ty else TypeId.fromName(p.type_name),
        });
    }

    const ret_type = if (func.return_type) |rt| TypeId.fromName(rt) else .void;

    var body = hir.HirBlock{
        .label = try allocator.dupe(u8, "entry"),
        .stmts = std.ArrayList(hir.Stmt).init(allocator),
    };

    for (func.body_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (parseStmt(allocator, trimmed)) |stmt| {
            try body.stmts.append(stmt);
        }
    }

    return .{
        .name = try allocator.dupe(u8, func.name),
        .params = params,
        .body = body,
        .return_type = ret_type,
        .linkage = if (func.is_export) .@"export" else .internal,
    };
}

fn lowerState(allocator: Allocator, state: ast.StateDefNode, sema_ctx: SemaContext) !hir.HirState {
    var variables = std.ArrayList(hir.HirState.StateVar).init(allocator);
    for (state.variables.items) |v| {
        const default_val = if (v.default_value) |dv|
            parseExpr(allocator, dv) catch null
        else
            null;

        try variables.append(.{
            .name = try allocator.dupe(u8, v.name),
            .ty = TypeId.fromName(v.type_name),
            .default = default_val,
        });
    }

    var transitions = std.ArrayList(hir.HirState.Transition).init(allocator);
    for (state.transitions.items) |t| {
        try transitions.append(.{
            .event = if (t.event_name) |en| try allocator.dupe(u8, en) else null,
            .target = try allocator.dupe(u8, t.target),
            .guard = if (t.guard) |g| parseExpr(allocator, g) catch null else null,
            .weight = t.hot_weight,
        });
    }

    const enter_body = if (state.enter_body) |body| blk: {
        var block = hir.HirBlock{
            .label = try allocator.dupe(u8, "enter"),
            .stmts = std.ArrayList(hir.Stmt).init(allocator),
        };
        var pos: usize = 0;
        while (pos < body.len) {
            while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) : (pos += 1) {}
            if (pos >= body.len) break;
            var end = pos;
            while (end < body.len and body[end] != ';') : (end += 1) {}
            const stmt_str = std.mem.trim(u8, body[pos..end], " \t\r\n");
            if (stmt_str.len > 0) {
                if (parseStmt(allocator, stmt_str)) |stmt| {
                    try block.stmts.append(stmt);
                }
            }
            pos = end + 1;
        }
        break :blk block;
    } else null;

    return .{
        .name = try allocator.dupe(u8, state.name),
        .variables = variables,
        .enter_body = enter_body,
        .exit_body = null,
        .transitions = transitions,
    };
}

fn parseStmt(allocator: Allocator, line: []const u8) ?hir.Stmt {
    if (std.mem.startsWith(u8, line, "return")) {
        const rest = std.mem.trim(u8, line["return".len..], " \t\r\n");
        if (rest.len == 0) return .{ .return_stmt = null };
        const expr = parseExpr(allocator, rest) catch return null;
        return .{ .return_stmt = expr };
    }

    if (std.mem.startsWith(u8, line, "var ")) {
        const rest = std.mem.trim(u8, line["var ".len..], " \t\r\n");
        const name = extractName(rest);
        if (name.len == 0) return null;

        var var_type: TypeId = .i64_type;
        if (extractVarType(rest)) |vt| {
            var_type = TypeId.fromName(vt);
        }

        const init = if (std.mem.indexOfScalar(u8, rest, '=')) |eq|
            parseExpr(allocator, std.mem.trim(u8, rest[eq + 1 ..], " \t\r\n")) catch null
        else
            null;

        return .{ .var_decl = .{
            .name = name,
            .ty = var_type,
            .init = init,
        } };
    }

    if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "if(")) {
        return parseIf(allocator, line);
    }

    if (std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "while(")) {
        return parseWhile(allocator, line);
    }

    if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
        const lhs = std.mem.trim(u8, line[0..eq_idx], " \t\r\n");
        const rhs = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r\n");
        if (lhs.len > 0 and rhs.len > 0 and isIdent(lhs)) {
            const value = parseExpr(allocator, rhs) catch return null;
            return .{ .assign = .{ .name = lhs, .value = value } };
        }
    }

    if (parseExpr(allocator, line)) |expr| {
        return .{ .expr_stmt = expr };
    }
    return null;
}

fn parseExpr(allocator: Allocator, expr: []const u8) ?hir.Expr {
    const t = std.mem.trim(u8, expr, " \t\r\n");
    if (t.len == 0) return null;

    if (std.mem.eql(u8, t, "true")) return .{ .literal_bool = true };
    if (std.mem.eql(u8, t, "false")) return .{ .literal_bool = false };

    if (t[0] == '"') {
        const eq = std.mem.lastIndexOfScalar(u8, t, '"') orelse t.len;
        return .{ .literal_string = t[1..eq] };
    }

    if (std.ascii.isDigit(t[0]) or (t.len > 1 and t[0] == '-' and std.ascii.isDigit(t[1]))) {
        const val = std.fmt.parseInt(i64, t, 10) catch return null;
        return .{ .literal_int = val };
    }

    if (t[0] == '(') {
        if (findParenEnd(t, 0)) |end| {
            if (end == t.len - 1) return parseExpr(allocator, t[1..end]);
        }
    }

    if (std.mem.indexOfScalar(u8, t, '(')) |pp| {
        if (pp > 0) {
            const nm = std.mem.trim(u8, t[0..pp], " \t\r\n");
            if (findParenEnd(t, pp)) |c| {
                const args_str = std.mem.trim(u8, t[pp + 1 .. c], " \t\r\n");
                var args = std.ArrayList(hir.Expr).init(allocator);
                defer args.deinit();
                parseArgList(allocator, args_str, &args) catch return null;
                return .{ .call = .{
                    .name = nm,
                    .args = args.toOwnedSlice() catch return null,
                } };
            }
        }
    }

    const bin_ops = [_]struct { []const u8, hir.BinOp }{
        .{ "+", .add }, .{ "-", .sub }, .{ "*", .mul },
        .{ "/", .div }, .{ "%", .mod },
        .{ "==", .eq }, .{ "!=", .ne },
        .{ "<=", .le }, .{ ">=", .ge },
        .{ "<", .lt },  .{ ">", .gt },
        .{ "&&", .@"and" }, .{ "||", .@"or" },
    };
    for (bin_ops) |pair| {
        if (findBinOp(t, pair[0])) |parts| {
            const left = parseExpr(allocator, parts.left) orelse return null;
            const right = parseExpr(allocator, parts.right) orelse return null;
            const left_ptr = allocator.create(hir.Expr) catch return null;
            left_ptr.* = left;
            const right_ptr = allocator.create(hir.Expr) catch return null;
            right_ptr.* = right;
            return .{ .binary = .{
                .op = pair[1],
                .left = left_ptr,
                .right = right_ptr,
            } };
        }
    }

    if (t[0] == '-' and t.len > 1) {
        const inner = parseExpr(allocator, t[1..]) orelse return null;
        const inner_ptr = allocator.create(hir.Expr) catch return null;
        inner_ptr.* = inner;
        return .{ .unary = .{ .op = .neg, .operand = inner_ptr } };
    }

    return .{ .variable = t };
}

fn parseIf(allocator: Allocator, line: []const u8) ?hir.Stmt {
    const rest = std.mem.trim(u8, line[3..], " \t\r\n");
    const cb = findBraceBlock(rest) orelse return null;
    const cond_str = std.mem.trim(u8, rest[0 .. cb.body_start - 1], " \t\r\n");
    const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

    const cond = parseExpr(allocator, cond_str) orelse return null;
    const then_body = parseBody(allocator, body_str) orelse return null;

    return .{ .if_stmt = .{
        .cond = cond,
        .then_body = then_body,
        .else_body = null,
    } };
}

fn parseWhile(allocator: Allocator, line: []const u8) ?hir.Stmt {
    const rest = std.mem.trim(u8, line[6..], " \t\r\n");
    const cb = findBraceBlock(rest) orelse return null;
    const cond_str = std.mem.trim(u8, rest[0 .. cb.body_start - 1], " \t\r\n");
    const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

    const cond = parseExpr(allocator, cond_str) orelse return null;
    const body = parseBody(allocator, body_str) orelse return null;

    return .{ .while_stmt = .{
        .cond = cond,
        .body = body,
    } };
}

fn parseBody(allocator: Allocator, body: []const u8) ?[]const hir.Stmt {
    var stmts = std.ArrayList(hir.Stmt).init(allocator);
    var pos: usize = 0;
    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) : (pos += 1) {}
        if (pos >= body.len) break;
        var end = pos;
        var depth: i32 = 0;
        while (end < body.len) {
            if (body[end] == '(' or body[end] == '{') depth += 1;
            if (body[end] == ')' or body[end] == '}') {
                if (depth == 0) break;
                depth -= 1;
            }
            if (body[end] == ';' and depth == 0) break;
            end += 1;
        }
        const stmt_str = std.mem.trim(u8, body[pos..end], " \t\r\n");
        if (stmt_str.len > 0) {
            if (parseStmt(allocator, stmt_str)) |stmt| {
                stmts.append(stmt) catch return null;
            }
        }
        pos = end + 1;
    }
    return stmts.toOwnedSlice() catch return null;
}

fn parseArgList(allocator: Allocator, args_str: []const u8, list: *std.ArrayList(hir.Expr)) !void {
    if (args_str.len == 0) return;
    var depth: i32 = 0;
    var in_str = false;
    var start: usize = 0;
    for (args_str, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (in_str) continue;
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c == ',' and depth == 0) {
            const a = std.mem.trim(u8, args_str[start..i], " \t\r\n");
            if (a.len > 0) {
                if (parseExpr(allocator, a)) |expr| {
                    try list.append(expr);
                }
            }
            start = i + 1;
        }
    }
    const last = std.mem.trim(u8, args_str[start..], " \t\r\n");
    if (last.len > 0) {
        if (parseExpr(allocator, last)) |expr| {
            try list.append(expr);
        }
    }
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn extractName(rest: []const u8) []const u8 {
    const t = std.mem.trim(u8, rest, " \t\r\n");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isAlphanumeric(t[end]) or t[end] == '_')) : (end += 1) {}
    return t[0..end];
}

fn extractVarType(rest: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, rest, " \t\r\n");
    const colon_idx = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const after_colon = std.mem.trim(u8, t[colon_idx + 1 ..], " \t\r\n");
    var end: usize = 0;
    while (end < after_colon.len and std.ascii.isAlphanumeric(after_colon[end])) : (end += 1) {}
    if (end == 0) return null;
    return std.mem.trimRight(u8, after_colon[0..end], " \t\r\n");
}

const BraceBlock = struct { body_start: usize, body_end: usize };

fn findBraceBlock(text: []const u8) ?BraceBlock {
    var i: usize = 0;
    while (i < text.len and text[i] != '{') : (i += 1) {}
    if (i >= text.len) return null;
    const body_start = i + 1;
    var depth: i32 = 1;
    i = body_start;
    while (i < text.len and depth > 0) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') depth -= 1;
        i += 1;
    }
    return .{ .body_start = body_start, .body_end = i - 1 };
}

const BinParts = struct { left: []const u8, right: []const u8 };

fn findBinOp(expr: []const u8, op: []const u8) ?BinParts {
    var depth: i32 = 0;
    var i: usize = expr.len;
    while (i > 0) {
        i -= 1;
        if (expr[i] == ')') depth += 1;
        if (expr[i] == '(') depth -= 1;
        if (depth != 0) continue;
        if (i + op.len > expr.len) continue;
        if (!std.mem.eql(u8, expr[i .. i + op.len], op)) continue;
        if (i == 0) return null;
        if (i + op.len >= expr.len) return null;
        if (std.mem.eql(u8, op, "=") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "!") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "<") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, ">") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "&") and i + 1 < expr.len and expr[i + 1] == '&') continue;
        if (std.mem.eql(u8, op, "|") and i + 1 < expr.len and expr[i + 1] == '|') continue;
        const left = std.mem.trim(u8, expr[0..i], " \t\r\n");
        const right = std.mem.trim(u8, expr[i + op.len ..], " \t\r\n");
        if (left.len > 0 and right.len > 0) return .{ .left = left, .right = right };
    }
    return null;
}

fn findParenEnd(line: []const u8, open: usize) ?usize {
    if (open >= line.len or line[open] != '(') return null;
    var depth: i32 = 0;
    var i = open;
    while (i < line.len) {
        if (line[i] == '(') depth += 1;
        if (line[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        if (line[i] == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) {}
        }
        i += 1;
    }
    return null;
}
