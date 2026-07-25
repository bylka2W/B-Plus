const HirLowering = @import("lower.zig").HirLowering;
const LowerError = @import("lower.zig").LowerError;
const BodyId = @import("lower.zig").BodyId;
const ExprId = @import("lower.zig").ExprId;
const StmtId = @import("lower.zig").StmtId;
const AstStmtId = @import("lower.zig").AstStmtId;
const OwnerId = @import("../../foundation/ids/ids.zig").OwnerId;
const std = @import("std");

pub fn lowerFnBody(self: *HirLowering, body_stmt_id: AstStmtId) LowerError!BodyId {
    if (!body_stmt_id.isValid()) return BodyId.INVALID;

    const ast_stmt = self.ast.getStmt(body_stmt_id) orelse return BodyId.INVALID;
    const stmts = switch (ast_stmt) {
        .block => |b| b.stmts,
        else => &.{},
    };

    var hir_stmts = std.ArrayList(StmtId).init(self.hir.allocator());
    var last_expr = ExprId.INVALID;
    for (stmts) |sid| {
        const hir_sid = try self.lowerStmt(sid);
        hir_stmts.append(hir_sid) catch return error.OutOfMemory;
        const stmt = self.hir.getStmt(hir_sid) orelse continue;
        if (stmt.kind == .expr) {
            last_expr = stmt.kind.expr.expr;
        }
    }

    const block_id = try self.block(hir_stmts.toOwnedSlice() catch return error.OutOfMemory, last_expr, .{ .file_id = 0, .start = 0, .end = 0 });

    return self.hir.addBody(.{
        .owner = OwnerId.INVALID,
        .entry = block_id,
        .local_count = 0,
    });
}
