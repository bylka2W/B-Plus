const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");
const SourceSpan = @import("../source/location/span.zig").SourceSpan;
const HirLiteral = @import("literal.zig").HirLiteral;

pub const ExprId = ids.ExprId;
pub const StmtId = ids.StmtId;
pub const PatId = ids.PatId;
pub const TypeId = ids.TypeId;
pub const DefId = ids.DefId;
pub const LabelId = ids.LabelId;

pub const HirExpr = struct {
    span: SourceSpan,
    ty: TypeId,
    kind: HirExprKind,

    pub const HirExprKind = union(enum) {
        literal: LiteralExpr,
        path: PathExpr,
        binary: BinaryExpr,
        unary: UnaryExpr,
        call: CallExpr,
        method_call: MethodCallExpr,
        field: FieldExpr,
        index: IndexExpr,
        assign: AssignExpr,
        if_expr: IfExpr,
        while_expr: WhileExpr,
        for_expr: ForExpr,
        loop_expr: LoopExpr,
        block: BlockExpr,
        return_expr: ReturnExpr,
        break_expr: BreakExpr,
        continue_expr: ContinueExpr,
        closure: ClosureExpr,
        match_expr: MatchExpr,
        range: RangeExpr,
        type_cast: TypeCastExpr,
        ref: RefExpr,
        deref: DerefExpr,
        missing,

        pub const LiteralExpr = struct {
            value: HirLiteral,
        };

        pub const PathExpr = struct {
            def: DefId,
        };

        pub const BinaryExpr = struct {
            op: BinOp,
            left: ExprId,
            right: ExprId,
        };

        pub const UnaryExpr = struct {
            op: UnaryOp,
            operand: ExprId,
        };

        pub const CallExpr = struct {
            callee: ExprId,
            args: []const ExprId,
        };

        pub const MethodCallExpr = struct {
            object: ExprId,
            method: DefId,
            args: []const ExprId,
        };

        pub const FieldExpr = struct {
            object: ExprId,
            field: DefId,
        };

        pub const IndexExpr = struct {
            object: ExprId,
            index: ExprId,
        };

        pub const AssignExpr = struct {
            target: ExprId,
            value: ExprId,
        };

        pub const IfExpr = struct {
            condition: ExprId,
            then_branch: ExprId,
            else_branch: ExprId,
        };

        pub const WhileExpr = struct {
            condition: ExprId,
            body: ExprId,
        };

        pub const ForExpr = struct {
            iter_var: DefId,
            iterable: ExprId,
            body: ExprId,
        };

        pub const LoopExpr = struct {
            body: ExprId,
        };

        pub const BlockExpr = struct {
            stmts: []const StmtId,
            result: ExprId,
        };

        pub const ReturnExpr = struct {
            value: ExprId,
        };

        pub const BreakExpr = struct {
            label: LabelId,
            value: ExprId,
        };

        pub const ContinueExpr = struct {
            label: LabelId,
        };

        pub const ClosureExpr = struct {
            params: []const ClosureParam,
            return_type: TypeId,
            body: ExprId,
        };

        pub const ClosureParam = struct {
            span: SourceSpan,
            def: DefId,
            ty: TypeId,
            mutable: bool,
        };

        pub const MatchExpr = struct {
            scrutinee: ExprId,
            arms: []const MatchArm,
        };

        pub const MatchArm = struct {
            span: SourceSpan,
            pattern: PatId,
            guard: ExprId,
            body: ExprId,
        };

        pub const RangeExpr = struct {
            start: ExprId,
            end: ExprId,
            inclusive: bool,
        };

        pub const TypeCastExpr = struct {
            operand: ExprId,
            target_type: TypeId,
        };

        pub const RefExpr = struct {
            operand: ExprId,
            mutable: bool,
        };

        pub const DerefExpr = struct {
            operand: ExprId,
        };
    };
};

pub const BinOp = enum {
    add, sub, mul, div, mod,
    eq, ne, lt, gt, le, ge,
    and_, or_,
    bitwise_and, bitwise_or, bitwise_xor, shl, shr,
};

pub const UnaryOp = enum {
    negate, not, bitwise_not, borrow, address_of, dereference,
};
