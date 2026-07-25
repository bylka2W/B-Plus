const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;

pub fn lowerBlockExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .block => |b| {
            const stmts = try self.lowerStmtSlice(b.stmts);
            const last = if (stmts.len > 0) blk: {
                const last_sid = stmts[stmts.len - 1];
                const stmt = self.hir.getStmt(last_sid) orelse break :blk try self.missingExpr(b.span);
                if (stmt.kind == .expr) break :blk stmt.kind.expr.expr;
                break :blk try self.missingExpr(b.span);
            } else try self.missingExpr(b.span);
            return self.block(stmts, last, b.span);
        },
        .paren => |p| self.lowerExpr(p.inner),
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
