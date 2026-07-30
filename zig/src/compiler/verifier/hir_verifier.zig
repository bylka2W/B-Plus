const std = @import("std");
const hir_arena = @import("../frontend/hir/arena.zig");
const verified = @import("verified_hir.zig");

const HirArena = hir_arena.HirArena;
const VerifiedHIR = verified.VerifiedHIR;
const HirItem = hir_arena.HirItem;
const HirBody = hir_arena.HirBody;
const HirExpr = hir_arena.HirExpr;
const HirStmt = hir_arena.HirStmt;
const HirPattern = hir_arena.HirPattern;
const ExprId = hir_arena.ExprId;
const StmtId = hir_arena.StmtId;
const ItemId = hir_arena.ItemId;
const BodyId = hir_arena.BodyId;
const SymbolId = @import("../frontend/foundation/ids/ids.zig").SymbolId;
const PatId = hir_arena.PatId;
const TypeId = hir_arena.TypeId;

pub const HirVerifyError = error{
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
    UndefinedVariable,
    UninitializedVariable,
    TypeError,
    Unsupported,
};

pub fn verifyHIR(arena: *HirArena) HirVerifyError!VerifiedHIR {
    try structuralCheck(arena);
    try scopeCheck(arena);
    try initCheck(arena);
    return VerifiedHIR{ .arena = arena };
}

fn structuralCheck(arena: *const HirArena) HirVerifyError!void {
    var i: u32 = 0;
    while (i < arena.itemCount()) : (i += 1) {
        const item_id = ItemId.new(i);
        const item = arena.getItem(item_id) orelse continue;
        try verifyItemStruct(arena, item);
    }
}

fn verifyItemStruct(arena: *const HirArena, item: HirItem) HirVerifyError!void {
    switch (item.kind) {
        .fn_decl => |f| {
            if (f.body.isValid()) {
                const body = arena.getBody(f.body) orelse return error.InvalidBodyId;
                try verifyBodyStruct(arena, body);
            }
        },
        .const_item => |c| {
            if (!c.init.isValid()) return error.InvalidExprId;
            _ = arena.getExpr(c.init) orelse return error.InvalidExprId;
        },
        .state_item => |st| {
            if (st.entry) |body_id| {
                const body = arena.getBody(body_id) orelse return error.InvalidBodyId;
                try verifyBodyStruct(arena, body);
            }
            if (st.exit) |body_id| {
                const body = arena.getBody(body_id) orelse return error.InvalidBodyId;
                try verifyBodyStruct(arena, body);
            }
        },
        .kernel_item => |k| {
            for (k.entries) |e| {
                if (e.body.isValid()) {
                    const body = arena.getBody(e.body) orelse return error.InvalidBodyId;
                    try verifyBodyStruct(arena, body);
                }
            }
        },
        else => {},
    }
}

fn verifyBodyStruct(arena: *const HirArena, body: HirBody) HirVerifyError!void {
    if (body.entry.isValid()) {
        _ = arena.getExpr(body.entry) orelse return error.InvalidExprId;
        try verifyExprStruct(arena, body.entry);
    }
}

fn verifyExprStruct(arena: *const HirArena, expr_id: ExprId) HirVerifyError!void {
    const expr = arena.getExpr(expr_id) orelse return error.InvalidExprId;
    switch (expr.kind) {
        .binary => |b| {
            if (!b.left.isValid()) return error.InvalidExprId;
            if (!b.right.isValid()) return error.InvalidExprId;
            try verifyExprStruct(arena, b.left);
            try verifyExprStruct(arena, b.right);
        },
        .unary => |u| {
            if (!u.operand.isValid()) return error.InvalidExprId;
            try verifyExprStruct(arena, u.operand);
        },
        .call => |c| {
            if (!c.callee.isValid()) return error.InvalidExprId;
            try verifyExprStruct(arena, c.callee);
            for (c.args) |arg| {
                if (!arg.isValid()) return error.InvalidExprId;
                try verifyExprStruct(arena, arg);
            }
        },
        .block => |b| {
            for (b.stmts) |sid| {
                if (!sid.isValid()) return error.InvalidStmtId;
                _ = arena.getStmt(sid) orelse return error.InvalidStmtId;
                try verifyStmtStruct(arena, sid);
            }
            if (b.result.isValid()) {
                try verifyExprStruct(arena, b.result);
            }
        },
        .if_expr => |i| {
            if (!i.condition.isValid()) return error.InvalidExprId;
            if (!i.then_branch.isValid()) return error.InvalidExprId;
            if (!i.else_branch.isValid()) return error.InvalidExprId;
            try verifyExprStruct(arena, i.condition);
            try verifyExprStruct(arena, i.then_branch);
            try verifyExprStruct(arena, i.else_branch);
        },
        .assign => |a| {
            if (!a.target.isValid()) return error.InvalidExprId;
            if (!a.value.isValid()) return error.InvalidExprId;
            try verifyExprStruct(arena, a.target);
            try verifyExprStruct(arena, a.value);
        },
        .while_expr => |w| {
            if (!w.condition.isValid()) return error.InvalidExprId;
            if (!w.body.isValid()) return error.InvalidExprId;
            try verifyExprStruct(arena, w.condition);
            try verifyExprStruct(arena, w.body);
        },
        .return_expr => |r| {
            if (r.value.isValid()) {
                try verifyExprStruct(arena, r.value);
            }
        },
        .literal, .path, .missing => {},
        else => {},
    }
}

fn verifyStmtStruct(arena: *const HirArena, stmt_id: StmtId) HirVerifyError!void {
    const stmt = arena.getStmt(stmt_id) orelse return error.InvalidStmtId;
    switch (stmt.kind) {
        .local_decl => |l| {
            if (!l.pattern.isValid()) return error.InvalidPatternId;
            _ = arena.getPattern(l.pattern) orelse return error.InvalidPatternId;
            if (l.init) |init_expr| {
                if (!init_expr.isValid()) return error.InvalidExprId;
                try verifyExprStruct(arena, init_expr);
            }
        },
        .expr => |e| {
            if (!e.expr.isValid()) return error.InvalidExprId;
            try verifyExprStruct(arena, e.expr);
        },
        .block => |b| {
            for (b.stmts) |sid| {
                if (!sid.isValid()) return error.InvalidStmtId;
                try verifyStmtStruct(arena, sid);
            }
        },
        .if_stmt => |ifs| {
            if (!ifs.condition.isValid()) return error.InvalidExprId;
            if (!ifs.then_branch.isValid()) return error.InvalidStmtId;
            try verifyExprStruct(arena, ifs.condition);
            try verifyStmtStruct(arena, ifs.then_branch);
            if (ifs.else_branch) |eb| {
                try verifyStmtStruct(arena, eb);
            }
        },
        .while_stmt => |ws| {
            if (!ws.condition.isValid()) return error.InvalidExprId;
            if (!ws.body.isValid()) return error.InvalidStmtId;
            try verifyExprStruct(arena, ws.condition);
            try verifyStmtStruct(arena, ws.body);
        },
        .return_stmt => |rs| {
            if (rs.value) |v| {
                if (!v.isValid()) return error.InvalidExprId;
                try verifyExprStruct(arena, v);
            }
        },
        else => {},
    }
}

fn scopeCheck(arena: *const HirArena) HirVerifyError!void {
    var i: u32 = 0;
    while (i < arena.itemCount()) : (i += 1) {
        const item_id = ItemId.new(i);
        const item = arena.getItem(item_id) orelse continue;
        try scopeCheckItem(arena, item);
    }
}

fn scopeCheckItem(arena: *const HirArena, item: HirItem) HirVerifyError!void {
    switch (item.kind) {
        .fn_decl => |f| {
            if (f.body.isValid()) {
                const body = arena.getBody(f.body) orelse return;
                var scope = ScopeContext{ .arena = arena, .defined = std.AutoHashMap(SymbolId, void).init(std.heap.page_allocator) };
                defer scope.defined.deinit();
                for (f.params) |p| {
                    scope.defined.put(p.name, {}) catch {};
                }
                try scope.checkExpr(body.entry);
            }
        },
        .state_item => |st| {
            if (st.entry) |body_id| {
                if (arena.getBody(body_id)) |body| {
                    var scope = ScopeContext{ .arena = arena, .defined = std.AutoHashMap(SymbolId, void).init(std.heap.page_allocator) };
                    defer scope.defined.deinit();
                    try scope.checkExpr(body.entry);
                }
            }
        },
        else => {},
    }
}

const ScopeContext = struct {
    arena: *const HirArena,
    defined: std.AutoHashMap(SymbolId, void),

    fn checkExpr(self: *ScopeContext, expr_id: ExprId) HirVerifyError!void {
        const expr = self.arena.getExpr(expr_id) orelse return;
        switch (expr.kind) {
            .block => |b| {
                for (b.stmts) |sid| try self.checkStmt(sid);
                if (b.result.isValid()) try self.checkExpr(b.result);
            },
            .binary => |b| {
                try self.checkExpr(b.left);
                try self.checkExpr(b.right);
            },
            .unary => |u| try self.checkExpr(u.operand),
            .call => |c| {
                try self.checkExpr(c.callee);
                for (c.args) |arg| try self.checkExpr(arg);
            },
            .if_expr => |i| {
                try self.checkExpr(i.condition);
                try self.checkExpr(i.then_branch);
                try self.checkExpr(i.else_branch);
            },
            .assign => |a| {
                try self.checkExpr(a.target);
                try self.checkExpr(a.value);
            },
            .while_expr => |w| {
                try self.checkExpr(w.condition);
                try self.checkExpr(w.body);
            },
            .return_expr => |r| {
                if (r.value.isValid()) try self.checkExpr(r.value);
            },
            .path => |p| {
                _ = p;
            },
            .literal, .missing => {},
            else => {},
        }
    }

    fn checkStmt(self: *ScopeContext, stmt_id: StmtId) HirVerifyError!void {
        const stmt = self.arena.getStmt(stmt_id) orelse return;
        switch (stmt.kind) {
            .local_decl => |l| {
                if (l.init) |init_expr| {
                    try self.checkExpr(init_expr);
                }
            },
            .expr => |e| try self.checkExpr(e.expr),
            .block => |b| {
                for (b.stmts) |sid| try self.checkStmt(sid);
            },
            .if_stmt => |ifs| {
                try self.checkExpr(ifs.condition);
                try self.checkStmt(ifs.then_branch);
                if (ifs.else_branch) |eb| try self.checkStmt(eb);
            },
            .while_stmt => |ws| {
                try self.checkExpr(ws.condition);
                try self.checkStmt(ws.body);
            },
            .return_stmt => |rs| {
                if (rs.value) |v| try self.checkExpr(v);
            },
            else => {},
        }
    }
};

fn initCheck(arena: *const HirArena) HirVerifyError!void {
    _ = arena;
}
