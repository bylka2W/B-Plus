const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;

pub fn lowerBinaryExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .binary => |b| {
            const left = try self.lowerExpr(b.left);
            const right = try self.lowerExpr(b.right);
            const op = self.lowerBinOp(b.op);
            return self.binary(op, left, right, b.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
