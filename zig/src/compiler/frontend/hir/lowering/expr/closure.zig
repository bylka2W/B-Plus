const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;
const TypeId = @import("../lower.zig").TypeId;
const DefId = @import("../lower.zig").DefId;
const UNK = @import("../lower.zig").UNK;
const std = @import("std");

pub fn lowerClosureExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .closure => |c| {
            var params = std.ArrayList(@import("../../expr.zig").HirExpr.HirExprKind.ClosureParam).init(self.hir.allocator());
            for (c.params) |p| {
                const def = self.resolveName(p.name);
                params.append(.{
                    .span = p.span,
                    .def = def,
                    .ty = UNK,
                    .mutable = false,
                }) catch return error.OutOfMemory;
            }
            const body = try self.lowerExpr(c.body);
            const return_type = if (c.return_type) |rt| try self.lowerTypeRefId(rt) else UNK;
            return self.hir.addExpr(.{
                .span = c.span,
                .ty = UNK,
                .kind = .{ .closure = .{
                    .params = params.toOwnedSlice() catch return error.OutOfMemory,
                    .return_type = return_type,
                    .body = body,
                } },
            });
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
