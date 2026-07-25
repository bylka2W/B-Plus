const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;
const DefId = @import("../lower.zig").DefId;
const LabelId = @import("../lower.zig").LabelId;

pub fn lowerIfExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .if_expr => |i| {
            const cond = try self.lowerExpr(i.condition);
            const then_branch = try self.lowerExpr(i.then_block);
            const else_branch = if (i.else_branch) |eb| try self.lowerExpr(eb) else try self.missingExpr(i.span);
            return self.ifExpr(cond, then_branch, else_branch, i.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerWhileExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .while_expr => |w| {
            const cond = try self.lowerExpr(w.condition);
            const body = try self.lowerExpr(w.body);
            return self.whileExpr(cond, body, w.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerForExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .for_expr => |f| {
            const iterable = try self.lowerExpr(f.iterable);
            const body = try self.lowerExpr(f.body);
            const iter_def = self.resolveName(f.iter_var);
            return self.forExpr(iter_def, iterable, body, f.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerLoopExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .loop_expr => |l| {
            const body = try self.lowerExpr(l.body);
            return self.loopExpr(body, l.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerReturnExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .return_expr => |r| {
            const value = if (r.value) |v| try self.lowerExpr(v) else try self.missingExpr(r.span);
            return self.returnExpr(value, r.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerBreakExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .break_expr => |b| {
            const label = LabelId.INVALID;
            const value = try self.missingExpr(b.span);
            return self.breakExpr(label, value, b.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerContinueExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .continue_expr => |c| {
            return self.continueExpr(LabelId.INVALID, c.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
