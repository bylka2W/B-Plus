const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;

pub fn lowerAssignExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .assign => |a| {
            const target = try self.lowerExpr(a.target);
            const value = try self.lowerExpr(a.value);
            return self.assign(target, value, a.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
