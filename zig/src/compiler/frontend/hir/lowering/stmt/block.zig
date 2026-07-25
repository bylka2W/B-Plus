const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const StmtId = @import("../lower.zig").StmtId;

pub fn lowerBlockStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .block => |b| {
            const stmts = try self.lowerStmtSlice(b.stmts);
            return self.blockStmt(stmts, b.span);
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
