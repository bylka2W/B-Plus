const std = @import("std");
const HirLowering = @import("lower.zig").HirLowering;
const LowerError = @import("lower.zig").LowerError;
const ExprId = @import("lower.zig").ExprId;
const StmtId = @import("lower.zig").StmtId;
const PatId = @import("lower.zig").PatId;
const TypeId = @import("lower.zig").TypeId;
const DefId = @import("lower.zig").DefId;
const LabelId = @import("lower.zig").LabelId;
const SourceSpan = @import("../../source/location/span.zig").SourceSpan;
const UNK = @import("lower.zig").UNK;
const BinOp = @import("lower.zig").BinOp;
const UnaryOp = @import("lower.zig").UnaryOp;
const HirLiteral = @import("lower.zig").HirLiteral;

pub fn literal(self: *HirLowering, value: HirLiteral, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .literal = .{ .value = value } },
    });
}

pub fn path(self: *HirLowering, def: DefId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .path = .{ .def = def } },
    });
}

pub fn binary(self: *HirLowering, op: BinOp, left: ExprId, right: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .binary = .{ .op = op, .left = left, .right = right } },
    });
}

pub fn unary(self: *HirLowering, op: UnaryOp, operand: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .unary = .{ .op = op, .operand = operand } },
    });
}

pub fn call(self: *HirLowering, callee: ExprId, args: []const ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .call = .{ .callee = callee, .args = args } },
    });
}

pub fn block(self: *HirLowering, stmts: []const StmtId, result: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .block = .{ .stmts = stmts, .result = result } },
    });
}

pub fn ifExpr(self: *HirLowering, cond: ExprId, then_branch: ExprId, else_branch: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .if_expr = .{ .condition = cond, .then_branch = then_branch, .else_branch = else_branch } },
    });
}

pub fn whileExpr(self: *HirLowering, cond: ExprId, body: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .while_expr = .{ .condition = cond, .body = body } },
    });
}

pub fn forExpr(self: *HirLowering, iter_var: DefId, iterable: ExprId, body: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .for_expr = .{ .iter_var = iter_var, .iterable = iterable, .body = body } },
    });
}

pub fn loopExpr(self: *HirLowering, body: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .loop_expr = .{ .body = body } },
    });
}

pub fn returnExpr(self: *HirLowering, value: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .return_expr = .{ .value = value } },
    });
}

pub fn breakExpr(self: *HirLowering, label: LabelId, value: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .break_expr = .{ .label = label, .value = value } },
    });
}

pub fn continueExpr(self: *HirLowering, label: LabelId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .continue_expr = .{ .label = label } },
    });
}

pub fn assign(self: *HirLowering, target: ExprId, value: ExprId, span: SourceSpan) LowerError!ExprId {
    return self.hir.addExpr(.{
        .span = span,
        .ty = UNK,
        .kind = .{ .assign = .{ .target = target, .value = value } },
    });
}

pub fn localDecl(self: *HirLowering, kind: @import("lower.zig").LocalKind, pat: PatId, type_ann: ?TypeId, init: ?ExprId, span: SourceSpan) LowerError!StmtId {
    return self.hir.addStmt(.{
        .span = span,
        .kind = .{ .local_decl = .{ .kind = kind, .pattern = pat, .type_annotation = type_ann, .init = init } },
    });
}

pub fn exprStmt(self: *HirLowering, expr: ExprId, span: SourceSpan) LowerError!StmtId {
    return self.hir.addStmt(.{
        .span = span,
        .kind = .{ .expr = .{ .expr = expr } },
    });
}

pub fn blockStmt(self: *HirLowering, stmts: []const StmtId, span: SourceSpan) LowerError!StmtId {
    return self.hir.addStmt(.{
        .span = span,
        .kind = .{ .block = .{ .stmts = stmts } },
    });
}

pub fn patternIdentifier(self: *HirLowering, def: DefId, ty: TypeId, mutable: bool, span: SourceSpan) LowerError!PatId {
    return self.hir.addPattern(.{
        .span = span,
        .kind = .{ .binding = .{ .def = def, .sub_pattern = PatId.INVALID, .ty = ty, .mutable = mutable } },
    });
}

pub fn patternWildcard(self: *HirLowering, span: SourceSpan) LowerError!PatId {
    return self.hir.addPattern(.{
        .span = span,
        .kind = .wildcard,
    });
}

pub fn patternLiteral(self: *HirLowering, value: HirLiteral, ty: TypeId, span: SourceSpan) LowerError!PatId {
    return self.hir.addPattern(.{
        .span = span,
        .kind = .{ .literal = .{ .value = value, .ty = ty } },
    });
}

pub fn patternTuple(self: *HirLowering, elements: []const PatId, ty: TypeId, span: SourceSpan) LowerError!PatId {
    return self.hir.addPattern(.{
        .span = span,
        .kind = .{ .tuple = .{ .elements = elements, .ty = ty } },
    });
}
