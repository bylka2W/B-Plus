const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;
const HirExpr = @import("../lower.zig").HirExpr;
const UNK = @import("../lower.zig").UNK;
const std = @import("std");

pub fn lowerMatchExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .match_expr => |m| {
            const scrutinee = try self.lowerExpr(m.scrutinee);
            var arms = std.ArrayList(HirExpr.HirExprKind.MatchArm).init(self.hir.allocator());
            for (m.arms) |arm| {
                const pat = try self.lowerPattern(arm.pattern);
                const body = try self.lowerExpr(arm.body);
                const guard = if (arm.guard) |g| try self.lowerExpr(g) else ExprId.INVALID;
                arms.append(.{
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                    .pattern = pat,
                    .guard = guard,
                    .body = body,
                }) catch return error.OutOfMemory;
            }
            return self.hir.addExpr(.{
                .span = m.span,
                .ty = UNK,
                .kind = .{ .match_expr = .{
                    .scrutinee = scrutinee,
                    .arms = arms.toOwnedSlice() catch return error.OutOfMemory,
                } },
            });
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
