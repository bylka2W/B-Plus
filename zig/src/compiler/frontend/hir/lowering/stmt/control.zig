const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const StmtId = @import("../lower.zig").StmtId;
const ExprId = @import("../lower.zig").ExprId;
const LabelId = @import("../lower.zig").LabelId;
const UNK = @import("../lower.zig").UNK;

pub fn lowerReturnStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .return_stmt => |r| {
            const value = if (r.value) |v| try self.lowerExpr(v) else try self.missingExpr(r.span);
            return self.hir.addStmt(.{
                .span = r.span,
                .kind = .{ .return_stmt = .{ .value = value } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerBreakStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .break_stmt => |b| {
            const value = try self.missingExpr(b.span);
            return self.hir.addStmt(.{
                .span = b.span,
                .kind = .{ .break_stmt = .{ .label = LabelId.INVALID, .value = value } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerContinueStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .continue_stmt => |c| {
            return self.hir.addStmt(.{
                .span = c.span,
                .kind = .{ .continue_stmt = .{ .label = LabelId.INVALID } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerDeferStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .defer_stmt => |d| {
            const body = try self.lowerStmt(d.body);
            return self.hir.addStmt(.{
                .span = d.span,
                .kind = .{ .defer_stmt = .{ .body = body } },
            });
        },
        .errdefer_stmt => |d| {
            const body = try self.lowerStmt(d.body);
            return self.hir.addStmt(.{
                .span = d.span,
                .kind = .{ .errdefer_stmt = .{ .body = body } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}

pub fn lowerIfStmt(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .if_stmt => |i| {
            const cond = try self.lowerExpr(i.condition);
            const then = try self.lowerStmt(i.then_block);
            const els = if (i.else_branch) |eb| try self.lowerStmt(eb) else try self.missingStmt(i.span);
            return self.hir.addStmt(.{
                .span = i.span,
                .kind = .{ .if_stmt = .{ .condition = cond, .then_branch = then, .else_branch = els } },
            });
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
