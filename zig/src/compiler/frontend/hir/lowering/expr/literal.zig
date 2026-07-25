const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ExprId = @import("../lower.zig").ExprId;
const HirLiteral = @import("../../literal.zig").HirLiteral;

pub fn lowerLiteralExpr(self: *HirLowering, ast_eid: @import("../lower.zig").AstExprId) LowerError!ExprId {
    const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_expr) {
        .literal => |l| {
            const lit_val: HirLiteral = switch (l.kind) {
                .integer => .{ .int = 0 },
                .float => .{ .float = 0.0 },
                .boolean => .{ .boolean = false },
                .string => .{ .string = @import("../lower.zig").SymbolId.INVALID },
                .char, .byte, .byte_string, .null_value => .{ .int = 0 },
            };
            return self.literal(lit_val, l.span);
        },
        else => return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
