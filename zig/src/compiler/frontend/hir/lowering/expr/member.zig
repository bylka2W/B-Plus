const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;
const DefId = @import("../lower.zig").DefId;

pub fn lowerMemberExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .member => |m| {
            const object = try self.lowerExpr(m.object);
            const field_def = self.resolveName(m.member);
            _ = field_def;
            return self.hir.addExpr(.{
                .span = m.span,
                .ty = @import("../lower.zig").UNK,
                .kind = .{ .field = .{ .object = object, .field = DefId.INVALID } },
            });
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
