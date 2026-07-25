const std = @import("std");
const HirLowering = @import("lower.zig").HirLowering;
const LowerError = @import("lower.zig").LowerError;
const ExprId = @import("lower.zig").ExprId;
const StmtId = @import("lower.zig").StmtId;
const PatId = @import("lower.zig").PatId;
const TypeId = @import("lower.zig").TypeId;
const TypeRefId = @import("lower.zig").AstTypeRefId;
const BinOp = @import("lower.zig").BinOp;
const UnaryOp = @import("lower.zig").UnaryOp;
const HirLiteral = @import("lower.zig").HirLiteral;
const SourceSpan = @import("../../source/location/span.zig").SourceSpan;
const ast_node = @import("../../ast/ast_node.zig");
const UNK = @import("lower.zig").UNK;

pub fn lowerExprSlice(self: *HirLowering, ast_ids: []const ExprId) LowerError![]const ExprId {
    var result = std.ArrayList(ExprId).init(self.hir.allocator());
    for (ast_ids) |eid| {
        const hir_id = try self.lowerExpr(eid);
        result.append(hir_id) catch return error.OutOfMemory;
    }
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn lowerStmtSlice(self: *HirLowering, ast_ids: []const StmtId) LowerError![]const StmtId {
    var result = std.ArrayList(StmtId).init(self.hir.allocator());
    for (ast_ids) |sid| {
        const hir_id = try self.lowerStmt(sid);
        result.append(hir_id) catch return error.OutOfMemory;
    }
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn lowerPatternSlice(self: *HirLowering, ast_ids: []const PatId) LowerError![]const PatId {
    var result = std.ArrayList(PatId).init(self.hir.allocator());
    for (ast_ids) |pid| {
        const hir_id = try self.lowerPattern(pid);
        result.append(hir_id) catch return error.OutOfMemory;
    }
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn lowerBinOp(self: *HirLowering, op: ast_node.BinOp) BinOp {
    _ = self;
    return switch (op) {
        .add => .add, .sub => .sub, .mul => .mul, .div => .div, .mod => .mod,
        .eq => .eq, .ne => .ne, .lt => .lt, .gt => .gt, .le => .le, .ge => .ge,
        .and_ => .and_, .or_ => .or_,
        .bitwise_and => .bitwise_and, .bitwise_or => .bitwise_or, .bitwise_xor => .bitwise_xor,
        .shl => .shl, .shr => .shr,
        .pow, .assign, .assign_add, .assign_sub, .assign_mul, .assign_div,
        .assign_mod, .assign_and, .assign_or, .assign_xor, .assign_shl,
        .assign_shr, .range, .range_inclusive => .add,
    };
}

pub fn lowerUnaryOp(self: *HirLowering, op: ast_node.UnaryOp) UnaryOp {
    _ = self;
    return switch (op) {
        .negate => .negate, .not => .not, .bitwise_not => .bitwise_not,
        .deref => .dereference, .address => .address_of, .ref => .borrow,
    };
}

pub fn lowerVisibility(self: *HirLowering, vis: ast_node.Visibility) @import("lower.zig").HirVisibility {
    _ = self;
    return switch (vis) {
        .public => .public, .private => .private, .package => .package,
    };
}

pub fn missingExpr(self: *HirLowering, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .missing,
    });
}

pub fn missingStmt(self: *HirLowering, span: SourceSpan) LowerError!StmtId {
    return self.hir.addStmt(.{
        .span = span,
        .kind = .missing,
    });
}

pub fn missingType(self: *HirLowering) LowerError!TypeId {
    return self.hir.addType(.{
        .builtin = .{ .kind = .void_type },
    });
}
