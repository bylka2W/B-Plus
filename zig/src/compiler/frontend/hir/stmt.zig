const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");
const SourceSpan = @import("../source/location/span.zig").SourceSpan;

pub const ExprId = ids.ExprId;
pub const StmtId = ids.StmtId;
pub const PatId = ids.PatId;
pub const ItemId = ids.ItemId;
pub const TypeId = ids.TypeId;
pub const DefId = ids.DefId;
pub const LabelId = ids.LabelId;

pub const HirStmt = struct {
    span: SourceSpan,
    kind: HirStmtKind,

    pub const HirStmtKind = union(enum) {
        local_decl: LocalDecl,
        expr: ExprStmt,
        block: BlockStmt,
        if_stmt: IfStmt,
        while_stmt: WhileStmt,
        for_stmt: ForStmt,
        loop_stmt: LoopStmt,
        return_stmt: ReturnStmt,
        break_stmt: BreakStmt,
        continue_stmt: ContinueStmt,
        defer_stmt: DeferStmt,
        errdefer_stmt: ErrdeferStmt,
        missing: MissingStmt,

        pub const LocalDecl = struct {
            kind: LocalKind,
            pattern: PatId,
            type_annotation: ?TypeId,
            init: ?ExprId,
        };

        pub const ExprStmt = struct {
            expr: ExprId,
        };

        pub const BlockStmt = struct {
            stmts: []const StmtId,
        };

        pub const IfStmt = struct {
            condition: ExprId,
            then_branch: StmtId,
            else_branch: ?StmtId,
        };

        pub const WhileStmt = struct {
            condition: ExprId,
            body: StmtId,
        };

        pub const ForStmt = struct {
            iter_var: DefId,
            iterable: ExprId,
            body: StmtId,
        };

        pub const LoopStmt = struct {
            body: StmtId,
        };

        pub const ReturnStmt = struct {
            value: ?ExprId,
        };

        pub const BreakStmt = struct {
            label: ?LabelId,
            value: ?ExprId,
        };

        pub const ContinueStmt = struct {
            label: ?LabelId,
        };

        pub const DeferStmt = struct {
            body: StmtId,
        };

        pub const ErrdeferStmt = struct {
            body: StmtId,
        };

        pub const MissingStmt = struct {};
    };
};

pub const LocalKind = enum {
    let,
    @"var",
    const_val,
};
