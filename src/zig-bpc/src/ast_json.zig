const std = @import("std");
const ast = @import("ast.zig");

pub fn parseJson(json: []const u8, allocator: std.mem.Allocator) anyerror!ast.Program {
    var tree = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .ignore_unknown_fields = true });
    defer tree.deinit();
    const root = tree.value;

    var program = ast.Program{
        .allocator = allocator,
        .entry = null,
        .start_state = "",
        .context_vars = std.ArrayList(ast.VarDecl).init(allocator),
        .states = std.ArrayList(ast.StateDecl).init(allocator),
        .fns = std.ArrayList(ast.FnDecl).init(allocator),
        .structs = std.ArrayList(ast.StructDecl).init(allocator),
        .kernels = std.ArrayList(ast.ComputeKernel).init(allocator),
    };

    // Entry
    if (root.object.get("entry")) |entryVal| {
        const name = try allocator.dupe(u8, entryVal.object.get("name").?.string);
        const raw_body = if (entryVal.object.get("body")) |b| try allocator.dupe(u8, b.string) else "";
        var body_stmts = std.ArrayList(ast.Stmt).init(allocator);
        if (entryVal.object.get("body_stmts")) |stmts| {
            body_stmts = try parseStmtArray(stmts, allocator);
        }
        program.entry = ast.EntryDecl{
            .name = name,
            .raw_body = raw_body,
            .body = body_stmts,
        };
    }

    // Start state (entry point for state-only programs)
    if (root.object.get("start_state")) |ss| {
        program.start_state = try allocator.dupe(u8, ss.string);
    }

    // Context vars
    if (root.object.get("vars")) |varsVal| {
        for (varsVal.array.items) |v| {
            const name = try allocator.dupe(u8, v.object.get("name").?.string);
            const var_type = try allocator.dupe(u8, v.object.get("type").?.string);
            const init_val = if (v.object.get("init")) |iv| try allocator.dupe(u8, iv.string) else "";
            const init_type = if (v.object.get("init_type")) |it| try allocator.dupe(u8, it.string) else "int";

            var vd = ast.VarDecl{
                .name = name,
                .var_type = if (var_type.len > 0) var_type else "int",
                .init = null,
            };

            if (init_val.len > 0) {
                vd.init = try parseLiteral(init_val, init_type, allocator);
            }

            try program.context_vars.append(vd);
        }
    }

    // States
    if (root.object.get("states")) |statesVal| {
        const statesArr = &statesVal.array;
        for (statesArr.items) |stateVal| {
            const state = try parseState(stateVal, allocator);
            try program.states.append(state);
        }
    }

    return program;
}

fn parseState(val: std.json.Value, allocator: std.mem.Allocator) anyerror!ast.StateDecl {
    var state = ast.StateDecl{
        .name = try allocator.dupe(u8, val.object.get("name").?.string),
        .vars = std.ArrayList(ast.VarDecl).init(allocator),
        .actions = std.ArrayList(ast.ActionDecl).init(allocator),
        .transitions = std.ArrayList(ast.Transition).init(allocator),
    };

    // Vars
    if (val.object.get("vars")) |varsVal| {
        for (varsVal.array.items) |v| {
            const name = try allocator.dupe(u8, v.object.get("name").?.string);
            const var_type = try allocator.dupe(u8, v.object.get("type").?.string);
            const init_val = if (v.object.get("init")) |iv| try allocator.dupe(u8, iv.string) else "";

            var vd = ast.VarDecl{
                .name = name,
                .var_type = if (var_type.len > 0) var_type else "int",
                .init = null,
            };

            if (init_val.len > 0) {
                const init_type = if (v.object.get("init_type")) |it| try allocator.dupe(u8, it.string) else "int";
                vd.init = try parseLiteral(init_val, init_type, allocator);
            }

            try state.vars.append(vd);
        }
    }

    // Actions (enter / exit)
    if (val.object.get("actions")) |actVal| {
        for (actVal.array.items) |a| {
            var body_stmts = std.ArrayList(ast.Stmt).init(allocator);
            if (a.object.get("body_stmts")) |stmts| {
                body_stmts = try parseStmtArray(stmts, allocator);
            }
            const act = ast.ActionDecl{
                .action_type = try allocator.dupe(u8, a.object.get("type").?.string),
                .raw_body = if (a.object.get("body")) |b| try allocator.dupe(u8, b.string) else "",
                .body_stmts = body_stmts,
            };
            try state.actions.append(act);
        }
    }

    // Transitions
    if (val.object.get("transitions")) |transVal| {
        for (transVal.array.items) |t| {
            var body_stmts = std.ArrayList(ast.Stmt).init(allocator);
            var guard_stmts = std.ArrayList(ast.Stmt).init(allocator);
            if (t.object.get("body_stmts")) |stmts| {
                body_stmts = try parseStmtArray(stmts, allocator);
            }
            if (t.object.get("guard_stmts")) |stmts| {
                guard_stmts = try parseStmtArray(stmts, allocator);
            }
            const tr = ast.Transition{
                .event = try allocator.dupe(u8, t.object.get("event").?.string),
                .target = try allocator.dupe(u8, t.object.get("target").?.string),
                .guard = if (t.object.get("guard")) |g| try allocator.dupe(u8, g.string) else "",
                .body = if (t.object.get("body")) |b| try allocator.dupe(u8, b.string) else "",
                .guard_stmts = guard_stmts,
                .body_stmts = body_stmts,
            };
            try state.transitions.append(tr);
        }
    }

    return state;
}

fn parseStmtArray(arr: std.json.Value, allocator: std.mem.Allocator) anyerror!std.ArrayList(ast.Stmt) {
    var list = std.ArrayList(ast.Stmt).init(allocator);
    for (arr.array.items) |item| {
        const stmt = try parseStmt(item, allocator);
        try list.append(stmt);
    }
    return list;
}

fn parseStmt(val: std.json.Value, allocator: std.mem.Allocator) anyerror!ast.Stmt {
    const obj = val.object;
    const kind = obj.get("kind").?;
    const kind_str = kind.string;

    if (std.mem.eql(u8, kind_str, "print")) {
        const args_arr = obj.get("args") orelse return error.MissingField;
        var args_list = std.ArrayList(*ast.Expr).init(allocator);
        for (args_arr.array.items) |arg_val| {
            const arg_expr = try allocator.create(ast.Expr);
            arg_expr.* = try parseExpr(arg_val, allocator);
            try args_list.append(arg_expr);
        }
        var print_arg: ?*ast.Expr = null;
        if (args_list.items.len > 0) {
            print_arg = args_list.items[0];
        }
        const empty = std.ArrayList(ast.Stmt).init(allocator);
        return ast.Stmt{ .kind = .print, .print_arg = print_arg, .print_args = args_list, .then_body = empty, .else_body = empty, .stmts = empty };
    }

    if (std.mem.eql(u8, kind_str, "assign")) {
        const target = try allocator.dupe(u8, obj.get("target").?.string);
        const op_s = obj.get("op").?.string;
        const op = if (std.mem.eql(u8, op_s, "+=")) "+=" else if (std.mem.eql(u8, op_s, "-=")) "-=" else "=";
        var rhs: ?*ast.Expr = null;
        if (obj.get("value")) |v| {
            rhs = try allocator.create(ast.Expr);
            rhs.?.* = try parseExpr(v, allocator);
        }
        const empty = std.ArrayList(ast.Stmt).init(allocator);
        return ast.Stmt{ .kind = .assign, .assign_name = target, .assign_op = op, .assign_expr = rhs, .then_body = empty, .else_body = empty, .stmts = empty };
    }

    if (std.mem.eql(u8, kind_str, "return")) {
        var ret_expr: ?*ast.Expr = null;
        if (obj.get("value")) |v| {
            ret_expr = try allocator.create(ast.Expr);
            ret_expr.?.* = try parseExpr(v, allocator);
        }
        const empty = std.ArrayList(ast.Stmt).init(allocator);
        return ast.Stmt{ .kind = .return_stmt, .return_expr = ret_expr, .then_body = empty, .else_body = empty, .stmts = empty };
    }

    if (std.mem.eql(u8, kind_str, "var_decl")) {
        const name = try allocator.dupe(u8, obj.get("name").?.string);
        const var_type = try allocator.dupe(u8, obj.get("type").?.string);
        var init: ?*ast.Expr = null;
        if (obj.get("init")) |v| {
            init = try allocator.create(ast.Expr);
            init.?.* = try parseExpr(v, allocator);
        }
        const empty = std.ArrayList(ast.Stmt).init(allocator);
        return ast.Stmt{
            .kind = .var_decl,
            .var_name = name,
            .var_type = if (var_type.len > 0) var_type else "inferred",
            .var_init = init,
            .then_body = empty,
            .else_body = empty,
            .stmts = empty,
        };
    }

    if (std.mem.eql(u8, kind_str, "if")) {
        const cond = try allocator.create(ast.Expr);
        cond.* = try parseExpr(obj.get("condition").?, allocator);
        const then_stmts = try parseStmtArray(obj.get("then").?, allocator);
        const else_stmts = try parseStmtArray(obj.get("else").?, allocator);
        return ast.Stmt{ .kind = .if_stmt, .condition = cond, .then_body = then_stmts, .else_body = else_stmts };
    }

    if (std.mem.eql(u8, kind_str, "while")) {
        const cond = try allocator.create(ast.Expr);
        cond.* = try parseExpr(obj.get("condition").?, allocator);
        const body_stmts = try parseStmtArray(obj.get("body").?, allocator);
        return ast.Stmt{ .kind = .while_stmt, .condition = cond, .stmts = body_stmts };
    }

    if (std.mem.eql(u8, kind_str, "block")) {
        const stmts = try parseStmtArray(obj.get("stmts").?, allocator);
        return ast.Stmt{ .kind = .block, .stmts = stmts };
    }

    if (std.mem.eql(u8, kind_str, "expr_stmt")) {
        const expr = try allocator.create(ast.Expr);
        expr.* = try parseExpr(obj.get("expr").?, allocator);
        const empty = std.ArrayList(ast.Stmt).init(allocator);
        return ast.Stmt{ .kind = .expr_stmt, .expr = expr, .then_body = empty, .else_body = empty, .stmts = empty };
    }

    return error.UnsupportedStmtKind;
}

fn parseExpr(val: std.json.Value, allocator: std.mem.Allocator) anyerror!ast.Expr {
    const obj = val.object;
    const kind = obj.get("kind").?;
    const kind_str = kind.string;

    if (std.mem.eql(u8, kind_str, "literal")) {
        const value = obj.get("value") orelse return error.MissingField;
        var lit = ast.Literal{
            .lit_type = .int,
            .int_val = 0,
            .float_val = 0.0,
            .string_val = "",
            .bool_val = false,
        };
        switch (value) {
            .integer => |iv| { lit.lit_type = .int; lit.int_val = iv; },
            .float => |fv| { lit.lit_type = .float; lit.float_val = fv; },
            .bool => |bv| { lit.lit_type = .boolean; lit.bool_val = bv; },
            .string => |sv| { lit.lit_type = .string; lit.string_val = try allocator.dupe(u8, sv); },
            else => return error.UnsupportedLiteralType,
        }
        const empty_args = std.ArrayList(*ast.Expr).init(allocator);
        return ast.Expr{ .kind = .literal, .literal = lit, .args = empty_args };
    }

    if (std.mem.eql(u8, kind_str, "ident")) {
        const name = try allocator.dupe(u8, obj.get("name").?.string);
        const empty_args = std.ArrayList(*ast.Expr).init(allocator);
        return ast.Expr{ .kind = .ident, .ident = name, .args = empty_args };
    }

    if (std.mem.eql(u8, kind_str, "binary")) {
        const op = try allocator.dupe(u8, obj.get("op").?.string);
        const left = try allocator.create(ast.Expr);
        left.* = try parseExpr(obj.get("left").?, allocator);
        const right = try allocator.create(ast.Expr);
        right.* = try parseExpr(obj.get("right").?, allocator);
        const empty_args = std.ArrayList(*ast.Expr).init(allocator);
        return ast.Expr{ .kind = .binary, .op = op, .left = left, .right = right, .args = empty_args };
    }

    if (std.mem.eql(u8, kind_str, "unary")) {
        const op = try allocator.dupe(u8, obj.get("op").?.string);
        const right = try allocator.create(ast.Expr);
        right.* = try parseExpr(obj.get("right").?, allocator);
        const empty_args = std.ArrayList(*ast.Expr).init(allocator);
        return ast.Expr{ .kind = .unary, .op = op, .right = right, .args = empty_args };
    }

    if (std.mem.eql(u8, kind_str, "postfix")) {
        const op = try allocator.dupe(u8, obj.get("op").?.string);
        const left = try allocator.create(ast.Expr);
        left.* = try parseExpr(obj.get("left").?, allocator);
        const empty_args = std.ArrayList(*ast.Expr).init(allocator);
        return ast.Expr{ .kind = .postfix, .op = op, .left = left, .args = empty_args };
    }

    if (std.mem.eql(u8, kind_str, "call")) {
        const callee = try allocator.dupe(u8, obj.get("callee").?.string);
        const args_val = obj.get("args") orelse return error.MissingField;
        var args = std.ArrayList(*ast.Expr).init(allocator);
        for (args_val.array.items) |a| {
            const arg_expr = try allocator.create(ast.Expr);
            arg_expr.* = try parseExpr(a, allocator);
            try args.append(arg_expr);
        }
        return ast.Expr{ .kind = .call, .callee = callee, .args = args };
    }

    return error.UnsupportedExprKind;
}

fn parseLiteral(val: []const u8, typ: []const u8, allocator: std.mem.Allocator) anyerror!*ast.Expr {
    var lit = ast.Literal{
        .lit_type = if (std.mem.eql(u8, typ, "int")) .int
            else if (std.mem.eql(u8, typ, "float")) .float
            else if (std.mem.eql(u8, typ, "bool")) .boolean
            else .string,
        .int_val = 0,
        .float_val = 0.0,
        .string_val = "",
        .bool_val = false,
    };

    if (lit.lit_type == .int) {
        lit.int_val = std.fmt.parseInt(i64, val, 10) catch 0;
    } else if (lit.lit_type == .float) {
        lit.float_val = std.fmt.parseFloat(f64, val) catch 0.0;
    } else if (lit.lit_type == .boolean) {
        lit.bool_val = std.mem.eql(u8, val, "true");
    } else {
        lit.string_val = val;
    }

    const expr = try allocator.create(ast.Expr);
    expr.* = ast.Expr{
        .kind = .literal,
        .literal = lit,
        .args = std.ArrayList(*ast.Expr).init(allocator),
    };
    return expr;
}
