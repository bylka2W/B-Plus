const std = @import("std");
const hir_mod = @import("../hir/arena.zig");
const HirArena = hir_mod.HirArena;
const HirExpr = hir_mod.HirExpr;
const HirStmt = hir_mod.HirStmt;
const HirItem = hir_mod.HirItem;
const type_sys = @import("../type_system/type_system.zig");
const TypeEngine = type_sys.TypeEngine;
const TypeId = type_sys.TypeId;
const ExprId = hir_mod.ExprId;
const StmtId = hir_mod.StmtId;
const ItemId = hir_mod.ItemId;

pub const VerifyTypedError = error{
    UnresolvedExprType,
    InvalidExprType,
    InvalidReturnType,
    TypeMismatch,
};

pub fn verifyTypedHIR(
    arena: *const HirArena,
    engine: *const TypeEngine,
) VerifyTypedError!void {
    var i: u32 = 0;
    while (i < arena.itemCount()) : (i += 1) {
        const item_id = ItemId.new(i);
        const item = arena.getItem(item_id) orelse continue;
        try verifyTypedItem(arena, engine, item);
    }
}

fn verifyTypedItem(
    arena: *const HirArena,
    engine: *const TypeEngine,
    item: HirItem,
) VerifyTypedError!void {
    switch (item.kind) {
        .fn_decl => |f| {
            if (f.body.isValid()) {
                if (arena.getBody(f.body)) |body| {
                    try verifyTypedExpr(arena, engine, body.entry);
                }
            }
        },
        .const_item => |c| {
            if (c.init.isValid()) {
                try verifyTypedExpr(arena, engine, c.init);
            }
        },
        .impl_item => |im| {
            for (im.methods) |m| {
                if (m.body.isValid()) {
                    if (arena.getBody(m.body)) |body| {
                        try verifyTypedExpr(arena, engine, body.entry);
                    }
                }
            }
        },
        else => {},
    }
}

fn verifyTypedExpr(
    arena: *const HirArena,
    engine: *const TypeEngine,
    expr_id: ExprId,
) VerifyTypedError!void {
    if (!expr_id.isValid()) return;
    const expr = arena.getExpr(expr_id) orelse return;

    if (!expr.ty.isValid()) return;

    if (engine.get(expr.ty)) |data| {
        if (data == .infer_var) {
            return error.UnresolvedExprType;
        }
    }

    switch (expr.kind) {
        .binary => |b| {
            if (b.left.isValid()) try verifyTypedExpr(arena, engine, b.left);
            if (b.right.isValid()) try verifyTypedExpr(arena, engine, b.right);
        },
        .unary => |u| {
            if (u.operand.isValid()) try verifyTypedExpr(arena, engine, u.operand);
        },
        .call => |c| {
            if (c.callee.isValid()) try verifyTypedExpr(arena, engine, c.callee);
            for (c.args) |arg| {
                if (arg.isValid()) try verifyTypedExpr(arena, engine, arg);
            }
        },
        .if_expr => |i| {
            if (i.condition.isValid()) try verifyTypedExpr(arena, engine, i.condition);
            if (i.then_branch.isValid()) try verifyTypedExpr(arena, engine, i.then_branch);
            if (i.else_branch.isValid()) try verifyTypedExpr(arena, engine, i.else_branch);
        },
        .assign => |a| {
            if (a.target.isValid()) try verifyTypedExpr(arena, engine, a.target);
            if (a.value.isValid()) try verifyTypedExpr(arena, engine, a.value);
        },
        .return_expr => |r| {
            if (r.value.isValid()) try verifyTypedExpr(arena, engine, r.value);
        },
        .block => |b| {
            for (b.stmts) |sid| {
                if (sid.isValid()) try verifyTypedStmt(arena, engine, sid);
            }
            if (b.result.isValid()) try verifyTypedExpr(arena, engine, b.result);
        },
        .while_expr => |w| {
            if (w.condition.isValid()) try verifyTypedExpr(arena, engine, w.condition);
            if (w.body.isValid()) try verifyTypedExpr(arena, engine, w.body);
        },
        .for_expr => |f| {
            if (f.iterable.isValid()) try verifyTypedExpr(arena, engine, f.iterable);
            if (f.body.isValid()) try verifyTypedExpr(arena, engine, f.body);
        },
        .loop_expr => |l| {
            if (l.body.isValid()) try verifyTypedExpr(arena, engine, l.body);
        },
        .break_expr => |b| {
            if (b.value.isValid()) try verifyTypedExpr(arena, engine, b.value);
        },
        .match_expr => |m| {
            if (m.scrutinee.isValid()) try verifyTypedExpr(arena, engine, m.scrutinee);
            for (m.arms) |arm| {
                if (arm.body.isValid()) try verifyTypedExpr(arena, engine, arm.body);
            }
        },
        .closure => |c| {
            if (c.body.isValid()) try verifyTypedExpr(arena, engine, c.body);
        },
        .field => |f| {
            if (f.object.isValid()) try verifyTypedExpr(arena, engine, f.object);
        },
        .index => |i| {
            if (i.object.isValid()) try verifyTypedExpr(arena, engine, i.object);
            if (i.index.isValid()) try verifyTypedExpr(arena, engine, i.index);
        },
        .range => |r| {
            if (r.start.isValid()) try verifyTypedExpr(arena, engine, r.start);
            if (r.end.isValid()) try verifyTypedExpr(arena, engine, r.end);
        },
        .type_cast => |tc| {
            if (tc.operand.isValid()) try verifyTypedExpr(arena, engine, tc.operand);
        },
        .ref => |r| {
            if (r.operand.isValid()) try verifyTypedExpr(arena, engine, r.operand);
        },
        .deref => |d| {
            if (d.operand.isValid()) try verifyTypedExpr(arena, engine, d.operand);
        },
        .method_call => |mc| {
            if (mc.object.isValid()) try verifyTypedExpr(arena, engine, mc.object);
            for (mc.args) |arg| {
                if (arg.isValid()) try verifyTypedExpr(arena, engine, arg);
            }
        },
        .path, .literal, .continue_expr, .missing => {},
    }
}

fn verifyTypedStmt(
    arena: *const HirArena,
    engine: *const TypeEngine,
    stmt_id: StmtId,
) VerifyTypedError!void {
    if (!stmt_id.isValid()) return;
    const stmt = arena.getStmt(stmt_id) orelse return;

    switch (stmt.kind) {
        .local_decl => |ld| {
            if (ld.init) |init_id| {
                if (init_id.isValid()) try verifyTypedExpr(arena, engine, init_id);
            }
        },
        .expr => |es| {
            if (es.expr.isValid()) try verifyTypedExpr(arena, engine, es.expr);
        },
        .block => |bs| {
            for (bs.stmts) |sid| {
                if (sid.isValid()) try verifyTypedStmt(arena, engine, sid);
            }
        },
        .if_stmt => |ifs| {
            if (ifs.condition.isValid()) try verifyTypedExpr(arena, engine, ifs.condition);
            if (ifs.then_branch.isValid()) try verifyTypedStmt(arena, engine, ifs.then_branch);
            if (ifs.else_branch) |eb| {
                if (eb.isValid()) try verifyTypedStmt(arena, engine, eb);
            }
        },
        .while_stmt => |ws| {
            if (ws.condition.isValid()) try verifyTypedExpr(arena, engine, ws.condition);
            if (ws.body.isValid()) try verifyTypedStmt(arena, engine, ws.body);
        },
        .for_stmt => |fs| {
            if (fs.iterable.isValid()) try verifyTypedExpr(arena, engine, fs.iterable);
            if (fs.body.isValid()) try verifyTypedStmt(arena, engine, fs.body);
        },
        .loop_stmt => |ls| {
            if (ls.body.isValid()) try verifyTypedStmt(arena, engine, ls.body);
        },
        .return_stmt => |rs| {
            if (rs.value) |val| {
                if (val.isValid()) try verifyTypedExpr(arena, engine, val);
            }
        },
        .break_stmt => |bs| {
            if (bs.value) |val| {
                if (val.isValid()) try verifyTypedExpr(arena, engine, val);
            }
        },
        .defer_stmt => |ds| {
            if (ds.body.isValid()) try verifyTypedStmt(arena, engine, ds.body);
        },
        .errdefer_stmt => |eds| {
            if (eds.body.isValid()) try verifyTypedStmt(arena, engine, eds.body);
        },
        .continue_stmt, .missing => {},
    }
}
