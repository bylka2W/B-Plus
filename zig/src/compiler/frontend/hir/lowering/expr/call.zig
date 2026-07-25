const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;
const std = @import("std");

pub fn lowerCallExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .call => |c| {
            const callee = try self.lowerExpr(c.callee);
            var args = std.ArrayList(ExprId).init(self.hir.allocator());
            for (c.args) |arg| {
                args.append(try self.lowerExpr(arg)) catch return error.OutOfMemory;
            }
            return self.call(callee, args.toOwnedSlice() catch return error.OutOfMemory, c.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
