const std = @import("std");
const ast = @import("ast.zig");

pub const Generator = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    prog: *const ast.Program = undefined,
    current_state: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Generator {
        return .{ .allocator = allocator, .buf = std.ArrayList(u8).init(allocator) };
    }

    pub fn generate(g: *Generator, prog: ast.Program) ![]const u8 {
        g.prog = &prog;
        try g.write("const std = @import(\"std\");\n\n");

        // B+ Context struct — global state
        const has_context = prog.context_vars.items.len > 0;
        _ = has_context;
        try g.write("const BPlusContext = struct {\n");
        for (prog.context_vars.items) |v| {
            try g.write("    ");
            try g.write(v.name);
            try g.write(": ");
            try g.write(g.mapType(v.var_type));
            if (v.init) |init_expr| {
                try g.write(" = ");
                try g.genExpr(init_expr);
            }
            try g.write(",\n");
        }
        // State-local vars
        for (prog.states.items) |st| {
            for (st.vars.items) |v| {
                try g.write("    ");
                try g.write(st.name);
                try g.write("_");
                try g.write(v.name);
                try g.write(": ");
                try g.write(g.mapType(v.var_type));
                if (v.init) |init_expr| {
                    try g.write(" = ");
                    try g.genExpr(init_expr);
                }
                try g.write(",\n");
            }
        }
        try g.write("    current_state: StateFn = ");
        try g.writeStateFnName(prog);
        try g.write(",\n");
        try g.write("};\n\n");

        // StateFn type
        try g.write("const StateFn = *const fn (ctx: *BPlusContext, event: []const u8) void;\n\n");

        // State handler functions
        for (prog.states.items) |st| {
            try g.genStateFn(st);
            try g.write("\n");
        }

        // Main entry point
        try g.write("pub fn main() !void {\n");
        try g.write("    var ctx = BPlusContext{};\n");
        // Initialize state-local vars from defaults
        for (prog.states.items) |st| {
            for (st.vars.items) |v| {
                if (v.init) |init_expr| {
                    try g.write("    ctx.");
                    try g.write(st.name);
                    try g.write("_");
                    try g.write(v.name);
                    try g.write(" = ");
                    try g.genExpr(init_expr);
                    try g.write(";\n");
                }
            }
        }
        try g.write("    ctx.current_state(&ctx, \"enter\");\n");
        try g.write("}\n");

        return g.buf.items;
    }

    fn writeStateFnName(g: *Generator, prog: ast.Program) !void {
        const base = if (prog.start_state.len > 0) prog.start_state
            else if (prog.entry) |_| "main_entry"
            else if (prog.states.items.len > 0) prog.states.items[0].name
            else "_start";
        try g.write(base);
        if (!std.mem.eql(u8, base, "_start") and !std.mem.eql(u8, base, "main_entry")) {
            try g.write("_enter");
        }
    }

    fn genStateFn(g: *Generator, st: ast.StateDecl) !void {
        g.current_state = st.name;
        const fname = try std.mem.concat(g.allocator, u8, &[_][]const u8{ st.name, "_enter" });
        defer g.allocator.free(fname);

        try g.write("fn ");
        try g.write(fname);
        try g.write("(ctx: *BPlusContext, event: []const u8) void {\n");

        var ctx_unused = true;

        // Handle enter action
        for (st.actions.items) |act| {
            if (std.mem.eql(u8, act.action_type, "enter")) {
                try g.write("    if (std.mem.eql(u8, event, \"enter\")) {\n");
                for (act.body_stmts.items) |stmt| {
                    try g.genStmtInState(stmt, 2);
                    if (stmt.kind == .assign) ctx_unused = false;
                }
                try g.write("        return;\n");
                try g.write("    }\n");
            }
        }

        // Handle exit action
        for (st.actions.items) |act| {
            if (std.mem.eql(u8, act.action_type, "exit")) {
                try g.write("    if (std.mem.eql(u8, event, \"exit\")) {\n");
                for (act.body_stmts.items) |stmt| {
                    try g.genStmtInState(stmt, 2);
                    if (stmt.kind == .assign) ctx_unused = false;
                }
                try g.write("        return;\n");
                try g.write("    }\n");
            }
        }

        // Group transitions by event name and emit grouped blocks
        {
            var seen = std.StringArrayHashMap(void).init(g.allocator);
            defer seen.deinit();
            for (st.transitions.items) |tr| {
                _ = seen.getOrPut(tr.event) catch {};
            }
            for (seen.keys()) |event_name| {
                ctx_unused = false;
                try g.write("    if (std.mem.eql(u8, event, \"");
                try g.writeEscaped(event_name);
                try g.write("\")) {\n");

                var guard_idx: usize = 0;
                for (st.transitions.items) |tr| {
                    if (!std.mem.eql(u8, tr.event, event_name)) continue;
                    const has_guard = tr.guard_stmts.items.len > 0 or tr.guard.len > 0;

                    // Emit body (unconditional for this event)
                    for (tr.body_stmts.items) |stmt| {
                        try g.genStmtInState(stmt, 2);
                    }

                    if (has_guard) {
                        try g.write("        if (");
                        if (tr.guard_stmts.items.len > 0) {
                            for (tr.guard_stmts.items, 0..) |gs, gi| {
                                if (gi > 0) try g.write(" and ");
                                if (gs.expr) |e| try g.genExprInState(e);
                            }
                        } else {
                            try g.write(tr.guard);
                        }
                        try g.write(") {\n");
                        if (tr.target.len > 0) {
                            try g.write("            ctx.current_state = ");
                            try g.write(tr.target);
                            try g.write("_enter;\n");
                            try g.write("            ctx.current_state(ctx, \"enter\");\n");
                        }
                        try g.write("            return;\n");
                        try g.write("        }\n");
                    } else {
                        if (tr.target.len > 0) {
                            try g.write("        ctx.current_state = ");
                            try g.write(tr.target);
                            try g.write("_enter;\n");
                            try g.write("        ctx.current_state(ctx, \"enter\");\n");
                        }
                        try g.write("        return;\n");
                        break; // unguarded is always last
                    }
                    guard_idx += 1;
                }
                try g.write("    }\n");
            }
        }

        if (ctx_unused) {
            try g.write("    _ = ctx;\n");
        }
        try g.write("}\n");
    }

    fn genStmtInState(g: *Generator, stmt: ast.Stmt, indent: usize) !void {
        var ws_buf: [128]u8 = undefined;
        var ws: []const u8 = "";
        if (indent * 4 < ws_buf.len) {
            @memset(ws_buf[0 .. indent * 4], ' ');
            ws = ws_buf[0 .. indent * 4];
        }
        switch (stmt.kind) {
            .print => {
                if (stmt.print_arg) |arg| {
                    try g.write(ws);
                    if (arg.kind == .literal and arg.literal.lit_type == .string) {
                        try g.write("std.debug.print(\"");
                        try g.writeEscaped(arg.literal.string_val);
                        try g.write("\\n\", .{});\n");
                    } else {
                        try g.write("std.debug.print(\"{any}\\n\", .{");
                        try g.genExpr(arg);
                        try g.write("});\n");
                    }
                }
            },
            .return_stmt => {
                try g.write(ws);
                try g.write("return");
                if (stmt.return_expr) |expr| {
                    try g.write(" ");
                    try g.genExprInState(expr);
                }
                try g.write(";\n");
            },
            .expr_stmt => {
                if (stmt.expr) |expr| {
                    try g.write(ws);
                    try g.genExprInState(expr);
                    try g.write(";\n");
                }
            },
            .var_decl => {
                try g.write(ws);
                try g.write("var ");
                try g.write(stmt.var_name);
                try g.write(": ");
                try g.write(g.mapType(stmt.var_type));
                if (stmt.var_init) |init_expr| {
                    try g.write(" = ");
                    try g.genExpr(init_expr);
                }
                try g.write(";\n");
            },
            .assign => {
                try g.write(ws);
                try g.write("ctx.");
                if (g.isStateLocalVar(stmt.assign_name)) {
                    try g.write(g.current_state);
                    try g.write("_");
                }
                try g.write(stmt.assign_name);
                try g.write(" ");
                try g.write(stmt.assign_op);
                try g.write(" ");
                if (stmt.assign_expr) |expr| {
                    try g.genExprInState(expr);
                }
                try g.write(";\n");
            },
            .if_stmt => {
                try g.write(ws);
                try g.write("if (");
                if (stmt.condition) |cond| {
                    try g.genExprInState(cond);
                }
                try g.write(") {\n");
                for (stmt.then_body.items) |s| {
                    try g.genStmtInState(s, indent + 1);
                }
                try g.write(ws);
                try g.write("}");
                if (stmt.else_body.items.len > 0) {
                    try g.write(" else {\n");
                    for (stmt.else_body.items) |s| {
                        try g.genStmtInState(s, indent + 1);
                    }
                    try g.write(ws);
                    try g.write("}");
                }
                try g.write("\n");
            },
            .while_stmt => {
                try g.write(ws);
                try g.write("while (");
                if (stmt.condition) |cond| {
                    try g.genExprInState(cond);
                }
                try g.write(") {\n");
                for (stmt.stmts.items) |s| {
                    try g.genStmtInState(s, indent + 1);
                }
                try g.write(ws);
                try g.write("}\n");
            },
            .block => {
                try g.write(ws);
                try g.write("{\n");
                for (stmt.stmts.items) |s| {
                    try g.genStmtInState(s, indent + 1);
                }
                try g.write(ws);
                try g.write("}\n");
            },
            else => {},
        }
    }

    fn genExprInState(g: *Generator, expr: *ast.Expr) !void {
        switch (expr.kind) {
            .ident => {
                if (g.isStateLocalVar(expr.ident)) {
                    try g.write("ctx.");
                    try g.write(g.current_state);
                    try g.write("_");
                } else {
                    try g.write("ctx.");
                }
                try g.write(expr.ident);
            },
            .binary => {
                if (expr.left == null or expr.right == null) return;
                try g.genExprInState(expr.left.?);
                try g.write(" ");
                try g.write(g.opToZig(expr.op));
                try g.write(" ");
                try g.genExprInState(expr.right.?);
            },
            .postfix => {
                if (expr.left) |l| try g.genExprInState(l);
                try g.write(g.opToZig(expr.op));
            },
            .unary => {
                try g.write(g.opToZig(expr.op));
                if (expr.right) |r| try g.genExprInState(r);
            },
            .call => {
                try g.write(expr.callee);
                try g.write("(");
                for (expr.args.items, 0..) |arg, i| {
                    if (i > 0) try g.write(", ");
                    try g.genExprInState(arg);
                }
                try g.write(")");
            },
            .literal => try g.genExpr(expr),
        }
    }

    fn genExpr(g: *Generator, expr: *ast.Expr) !void {
        switch (expr.kind) {
            .literal => {
                switch (expr.literal.lit_type) {
                    .int => try g.writeInt(expr.literal.int_val),
                    .float => try g.writeFloat(expr.literal.float_val),
                    .string => {
                        try g.write("\"");
                        try g.writeEscaped(expr.literal.string_val);
                        try g.write("\"");
                    },
                    .boolean => {
                        if (expr.literal.bool_val) { try g.write("true"); } else { try g.write("false"); }
                    },
                }
            },
            .ident => {
                try g.write(expr.ident);
            },
            .binary => {
                if (expr.left == null or expr.right == null) return;
                try g.genExpr(expr.left.?);
                try g.write(" ");
                try g.write(g.opToZig(expr.op));
                try g.write(" ");
                try g.genExpr(expr.right.?);
            },
            .postfix => {
                if (expr.left) |l| try g.genExpr(l);
                try g.write(g.opToZig(expr.op));
            },
            .unary => {
                try g.write(g.opToZig(expr.op));
                if (expr.right) |r| try g.genExpr(r);
            },
            .call => {
                try g.write(expr.callee);
                try g.write("(");
                for (expr.args.items, 0..) |arg, i| {
                    if (i > 0) try g.write(", ");
                    try g.genExpr(arg);
                }
                try g.write(")");
            },
        }
    }

    fn opToZig(_: *Generator, op: []const u8) []const u8 {
        if (std.mem.eql(u8, op, "&&")) return "and";
        if (std.mem.eql(u8, op, "||")) return "or";
        if (std.mem.eql(u8, op, "+=")) return "+=";
        if (std.mem.eql(u8, op, "++")) return " +=";
        if (std.mem.eql(u8, op, "--")) return " -=";
        return op;
    }

    fn mapType(_: *Generator, t: []const u8) []const u8 {
        if (std.mem.eql(u8, t, "int")) return "i32";
        if (std.mem.eql(u8, t, "uint")) return "u32";
        if (std.mem.eql(u8, t, "float")) return "f32";
        if (std.mem.eql(u8, t, "double")) return "f64";
        if (std.mem.eql(u8, t, "bool")) return "bool";
        if (std.mem.eql(u8, t, "byte")) return "u8";
        if (std.mem.eql(u8, t, "string")) return "[]const u8";
        if (std.mem.eql(u8, t, "void")) return "void";
        if (std.mem.eql(u8, t, "inferred")) return "i32";
        return t;
    }

    fn isStateLocalVar(g: *Generator, name: []const u8) bool {
        if (g.current_state.len == 0) return false;
        for (g.prog.states.items) |st| {
            if (!std.mem.eql(u8, st.name, g.current_state)) continue;
            for (st.vars.items) |v| {
                if (std.mem.eql(u8, v.name, name)) return true;
            }
        }
        return false;
    }

    fn write(g: *Generator, s: []const u8) !void {
        try g.buf.appendSlice(s);
    }

    fn writeInt(g: *Generator, v: i64) !void {
        try std.fmt.format(g.buf.writer(), "{d}", .{v});
    }

    fn writeFloat(g: *Generator, v: f64) !void {
        try std.fmt.format(g.buf.writer(), "{d}", .{v});
    }

    fn writeEscaped(g: *Generator, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\\' => try g.write("\\\\"),
                '"' => try g.write("\\\""),
                '\n' => try g.write("\\n"),
                '\r' => try g.write("\\r"),
                '\t' => try g.write("\\t"),
                else => try g.buf.append(c),
            }
        }
    }
};
