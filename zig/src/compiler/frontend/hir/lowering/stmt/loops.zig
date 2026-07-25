const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const StmtId = @import("../lower.zig").StmtId;
const DefId = @import("../lower.zig").DefId;

pub fn lowerForStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .for_stmt => |f| {
            const iterable = try self.lowerExpr(f.iterable);
            const body = try self.lowerStmt(f.body);
            const iter_def = self.resolveName(f.iter_var);
            return self.hir.addStmt(.{
                .span = f.span,
                .kind = .{ .for_stmt = .{ .iter_var = iter_def, .iterable = iterable, .body = body } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerWhileStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .while_stmt => |w| {
            const cond = try self.lowerExpr(w.condition);
            const body = try self.lowerStmt(w.body);
            return self.hir.addStmt(.{
                .span = w.span,
                .kind = .{ .while_stmt = .{ .condition = cond, .body = body } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerLoopStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .loop_stmt => |l| {
            const body = try self.lowerStmt(l.body);
            return self.hir.addStmt(.{
                .span = l.span,
                .kind = .{ .loop_stmt = .{ .body = body } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
