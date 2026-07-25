const std = @import("std");
const arena_mod = @import("arena.zig");
const HirArena = arena_mod.HirArena;

pub const VerifyError = error{
    InvalidExprId,
    InvalidStmtId,
    InvalidPatternId,
    InvalidTypeId,
    InvalidDefId,
    InvalidBodyId,
    InvalidItemId,
    OrphanBody,
    EmptyBody,
    MissingResult,
};

pub fn verifyHIR(arena: *const HirArena) VerifyError!void {
    var i: u32 = 0;
    while (i < arena.itemCount()) : (i += 1) {
        const item_id = arena_mod.ItemId.new(i);
        const item = arena.getItem(item_id) orelse continue;
        try verifyItem(arena, item);
    }
}

fn verifyItem(arena: *const HirArena, item: arena_mod.HirItem) VerifyError!void {
    switch (item.kind) {
        .fn_decl => |f| {
            if (f.body.isValid()) {
                const body = arena.getBody(f.body) orelse return error.InvalidBodyId;
                try verifyBody(arena, body);
            }
        },
        .const_item => |c| {
            if (!c.init.isValid()) return error.InvalidExprId;
            _ = arena.getExpr(c.init) orelse return error.InvalidExprId;
        },
        .impl_item => |im| {
            for (im.methods) |m| {
                if (m.body.isValid()) {
                    const b = arena.getBody(m.body) orelse return error.InvalidBodyId;
                    try verifyBody(arena, b);
                }
            }
        },
        .state_item => |st| {
            if (st.entry) |body_id| {
                const body = arena.getBody(body_id) orelse return error.InvalidBodyId;
                try verifyBody(arena, body);
            }
            if (st.exit) |body_id| {
                const body = arena.getBody(body_id) orelse return error.InvalidBodyId;
                try verifyBody(arena, body);
            }
        },
        .kernel_item => |k| {
            for (k.entries) |e| {
                if (e.body.isValid()) {
                    const body = arena.getBody(e.body) orelse return error.InvalidBodyId;
                    try verifyBody(arena, body);
                }
            }
        },
        else => {},
    }
}

fn verifyBody(arena: *const HirArena, body: arena_mod.HirBody) VerifyError!void {
    if (body.entry.isValid()) {
        _ = arena.getExpr(body.entry) orelse return error.InvalidExprId;
    }
}

pub fn verifyExpr(arena: *const HirArena, expr_id: arena_mod.ExprId) VerifyError!void {
    const expr = arena.getExpr(expr_id) orelse return error.InvalidExprId;
    switch (expr.kind) {
        .binary => |b| {
            if (!b.left.isValid()) return error.InvalidExprId;
            if (!b.right.isValid()) return error.InvalidExprId;
        },
        .unary => |u| {
            if (!u.operand.isValid()) return error.InvalidExprId;
        },
        .call => |c| {
            if (!c.callee.isValid()) return error.InvalidExprId;
        },
        .block => |b| {
            for (b.stmts) |sid| {
                if (!sid.isValid()) return error.InvalidStmtId;
                _ = arena.getStmt(sid) orelse return error.InvalidStmtId;
            }
        },
        .if_expr => |i| {
            if (!i.condition.isValid()) return error.InvalidExprId;
            if (!i.then_branch.isValid()) return error.InvalidExprId;
            if (!i.else_branch.isValid()) return error.InvalidExprId;
        },
        .assign => |a| {
            if (!a.target.isValid()) return error.InvalidExprId;
            if (!a.value.isValid()) return error.InvalidExprId;
        },
        .match_expr => |m| {
            if (!m.scrutinee.isValid()) return error.InvalidExprId;
            for (m.arms) |arm| {
                if (!arm.pattern.isValid()) return error.InvalidPatternId;
                if (!arm.body.isValid()) return error.InvalidExprId;
            }
        },
        else => {},
    }
}

pub fn verifyStmt(arena: *const HirArena, stmt_id: arena_mod.StmtId) VerifyError!void {
    const stmt = arena.getStmt(stmt_id) orelse return error.InvalidStmtId;
    switch (stmt.kind) {
        .local_decl => |l| {
            if (!l.pattern.isValid()) return error.InvalidPatternId;
            _ = arena.getPattern(l.pattern) orelse return error.InvalidPatternId;
            if (l.init.isValid()) {
                _ = arena.getExpr(l.init) orelse return error.InvalidExprId;
            }
        },
        .expr => |e| {
            if (!e.expr.isValid()) return error.InvalidExprId;
            _ = arena.getExpr(e.expr) orelse return error.InvalidExprId;
        },
        .block => |b| {
            for (b.stmts) |sid| {
                if (!sid.isValid()) return error.InvalidStmtId;
                _ = arena.getStmt(sid) orelse return error.InvalidStmtId;
            }
        },
        else => {},
    }
}

pub fn verifyPattern(arena: *const HirArena, pat_id: arena_mod.PatId) VerifyError!void {
    const pat = arena.getPattern(pat_id) orelse return error.InvalidPatternId;
    switch (pat.kind) {
        .binding => |b| {
            if (!b.sub_pattern.isValid()) return error.InvalidPatternId;
            _ = arena.getPattern(b.sub_pattern) orelse return error.InvalidPatternId;
        },
        .tuple => |t| {
            for (t.elements) |eid| {
                if (!eid.isValid()) return error.InvalidPatternId;
                _ = arena.getPattern(eid) orelse return error.InvalidPatternId;
            }
        },
        .struct_pat => |s| {
            for (s.fields) |f| {
                if (!f.pattern.isValid()) return error.InvalidPatternId;
                _ = arena.getPattern(f.pattern) orelse return error.InvalidPatternId;
            }
        },
        else => {},
    }
}
