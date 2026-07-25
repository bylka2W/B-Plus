const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;

pub fn lowerUnaryExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .unary => |u| {
            const operand = try self.lowerExpr(u.operand);
            const op = self.lowerUnaryOp(u.op);
            return self.unary(op, operand, u.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
