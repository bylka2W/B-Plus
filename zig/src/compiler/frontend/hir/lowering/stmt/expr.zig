const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const StmtId = @import("../lower.zig").StmtId;

pub fn lowerExprStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .expr_stmt => |e| {
            const expr = try self.lowerExpr(e.expr);
            return self.exprStmt(expr, e.span);
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
