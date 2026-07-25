const std = @import("std");
const source_span = @import("../source/location/span.zig");
const ids = @import("../foundation/ids/ids.zig");

pub const SourceSpan = source_span.SourceSpan;
pub const ExprId = ids.ExprId;
pub const StmtId = ids.StmtId;
pub const DeclId = ids.DeclId;
pub const PatId = ids.PatId;
pub const TypeRefId = ids.TypeRefId;
pub const ItemId = ids.ItemId;
pub const SymbolId = ids.SymbolId;

pub const AstNode = union(enum) {
    expr: AstExpr,
    stmt: AstStmt,
    decl: AstDecl,
    type_ref: AstTypeRef,
    pattern: AstPattern,
};

pub const AstExpr = union(enum) {
    literal: LiteralExpr,
    identifier: IdentifierExpr,
    binary: BinaryExpr,
    unary: UnaryExpr,
    call: CallExpr,
    member: MemberExpr,
    index: IndexExpr,
    paren: ParenExpr,
    if_expr: IfExpr,
    while_expr: WhileExpr,
    for_expr: ForExpr,
    loop_expr: LoopExpr,
    block: BlockExpr,
    assign: AssignExpr,
    return_expr: ReturnExpr,
    break_expr: BreakExpr,
    continue_expr: ContinueExpr,
    closure: ClosureExpr,
    match_expr: MatchExpr,
    range: RangeExpr,
    try_expr: TryExpr,
    type_cast: TypeCastExpr,
    missing: MissingExpr,

    pub const LiteralExpr = struct {
        kind: LiteralKind,
        symbol_id: u32,
        span: SourceSpan,
    };

    pub const IdentifierExpr = struct {
        name: SymbolId,
        span: SourceSpan,
    };

    pub const BinaryExpr = struct {
        op: BinOp,
        left: ExprId,
        right: ExprId,
        span: SourceSpan,
    };

    pub const UnaryExpr = struct {
        op: UnaryOp,
        operand: ExprId,
        span: SourceSpan,
    };

    pub const CallExpr = struct {
        callee: ExprId,
        args: []const ExprId,
        span: SourceSpan,
    };

    pub const MemberExpr = struct {
        object: ExprId,
        member: SymbolId,
        span: SourceSpan,
    };

    pub const IndexExpr = struct {
        object: ExprId,
        index: ExprId,
        span: SourceSpan,
    };

    pub const ParenExpr = struct {
        inner: ExprId,
        span: SourceSpan,
    };

    pub const IfExpr = struct {
        condition: ExprId,
        then_block: ExprId,
        else_branch: ?ExprId,
        span: SourceSpan,
    };

    pub const WhileExpr = struct {
        condition: ExprId,
        body: ExprId,
        span: SourceSpan,
    };

    pub const ForExpr = struct {
        iter_var: SymbolId,
        iterable: ExprId,
        body: ExprId,
        span: SourceSpan,
    };

    pub const LoopExpr = struct {
        body: ExprId,
        span: SourceSpan,
    };

    pub const BlockExpr = struct {
        stmts: []const StmtId,
        span: SourceSpan,
    };

    pub const AssignExpr = struct {
        target: ExprId,
        value: ExprId,
        span: SourceSpan,
    };

    pub const ReturnExpr = struct {
        value: ?ExprId,
        span: SourceSpan,
    };

    pub const BreakExpr = struct {
        label: ?SymbolId,
        span: SourceSpan,
    };

    pub const ContinueExpr = struct {
        label: ?SymbolId,
        span: SourceSpan,
    };

    pub const ClosureExpr = struct {
        params: []const ParamDef,
        return_type: ?TypeRefId,
        body: ExprId,
        span: SourceSpan,
    };

    pub const MatchExpr = struct {
        scrutinee: ExprId,
        arms: []const MatchArm,
        span: SourceSpan,
    };

    pub const MatchArm = struct {
        pattern: PatId,
        guard: ?ExprId,
        body: ExprId,
    };

    pub const RangeExpr = struct {
        start: ?ExprId,
        end: ?ExprId,
        inclusive: bool,
        span: SourceSpan,
    };

    pub const TryExpr = struct {
        operand: ExprId,
        span: SourceSpan,
    };

    pub const TypeCastExpr = struct {
        operand: ExprId,
        target_type: TypeRefId,
        span: SourceSpan,
    };

    pub const MissingExpr = struct {
        span: SourceSpan,
    };
};

pub const AstStmt = union(enum) {
    let: LetStmt,
    @"var": VarStmt,
    const_stmt: ConstStmt,
    expr_stmt: ExprStmt,
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

    pub const LetStmt = struct {
        pattern: PatId,
        type_annotation: ?TypeRefId,
        init: ?ExprId,
        span: SourceSpan,
    };

    pub const VarStmt = struct {
        pattern: PatId,
        type_annotation: ?TypeRefId,
        init: ?ExprId,
        span: SourceSpan,
    };

    pub const ConstStmt = struct {
        pattern: PatId,
        type_annotation: ?TypeRefId,
        init: ExprId,
        span: SourceSpan,
    };

    pub const ExprStmt = struct {
        expr: ExprId,
        span: SourceSpan,
    };

    pub const BlockStmt = struct {
        stmts: []const StmtId,
        span: SourceSpan,
    };

    pub const IfStmt = struct {
        condition: ExprId,
        then_block: StmtId,
        else_branch: ?StmtId,
        span: SourceSpan,
    };

    pub const WhileStmt = struct {
        condition: ExprId,
        body: StmtId,
        span: SourceSpan,
    };

    pub const ForStmt = struct {
        iter_var: SymbolId,
        iterable: ExprId,
        body: StmtId,
        span: SourceSpan,
    };

    pub const LoopStmt = struct {
        body: StmtId,
        span: SourceSpan,
    };

    pub const ReturnStmt = struct {
        value: ?ExprId,
        span: SourceSpan,
    };

    pub const BreakStmt = struct {
        label: ?SymbolId,
        span: SourceSpan,
    };

    pub const ContinueStmt = struct {
        label: ?SymbolId,
        span: SourceSpan,
    };

    pub const DeferStmt = struct {
        body: StmtId,
        span: SourceSpan,
    };

    pub const ErrdeferStmt = struct {
        body: StmtId,
        span: SourceSpan,
    };

    pub const MissingStmt = struct {
        span: SourceSpan,
    };
};

pub const AstDecl = union(enum) {
    fn_decl: FnDecl,
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    trait_decl: TraitDecl,
    impl_decl: ImplDecl,
    type_alias: TypeAliasDecl,
    import: ImportDecl,
    module: ModuleDecl,
    extern_fn: ExternFnDecl,
    missing: MissingDecl,

    pub const FnDecl = struct {
        name: SymbolId,
        params: []const ParamDef,
        return_type: ?TypeRefId,
        body: ?StmtId,
        visibility: Visibility,
        is_extern: bool,
        span: SourceSpan,
    };

    pub const StructDecl = struct {
        name: SymbolId,
        fields: []const FieldDef,
        visibility: Visibility,
        span: SourceSpan,
    };

    pub const EnumDecl = struct {
        name: SymbolId,
        variants: []const VariantDef,
        visibility: Visibility,
        span: SourceSpan,
    };

    pub const TraitDecl = struct {
        name: SymbolId,
        methods: []const FnDecl,
        visibility: Visibility,
        span: SourceSpan,
    };

    pub const ImplDecl = struct {
        self_type: TypeRefId,
        trait_ref: ?TypeRefId,
        methods: []const FnDecl,
        span: SourceSpan,
    };

    pub const TypeAliasDecl = struct {
        name: SymbolId,
        target_type: TypeRefId,
        visibility: Visibility,
        span: SourceSpan,
    };

    pub const ImportDecl = struct {
        path: SymbolId,
        alias: ?SymbolId,
        span: SourceSpan,
    };

    pub const ModuleDecl = struct {
        name: SymbolId,
        span: SourceSpan,
    };

    pub const ExternFnDecl = struct {
        name: SymbolId,
        params: []const ParamDef,
        return_type: ?TypeRefId,
        span: SourceSpan,
    };

    pub const MissingDecl = struct {
        span: SourceSpan,
    };
};

pub const AstTypeRef = union(enum) {
    named: NamedType,
    pointer: PointerType,
    array: ArrayType,
    slice: SliceType,
    tuple: TupleType,
    fn_type: FnType,
    optional: OptionalType,
    missing: MissingType,

    pub const NamedType = struct {
        name: SymbolId,
        type_args: []const TypeRefId,
        span: SourceSpan,
    };

    pub const PointerType = struct {
        mutable: bool,
        pointee: TypeRefId,
        span: SourceSpan,
    };

    pub const ArrayType = struct {
        element: TypeRefId,
        length: ?ExprId,
        span: SourceSpan,
    };

    pub const SliceType = struct {
        element: TypeRefId,
        span: SourceSpan,
    };

    pub const TupleType = struct {
        elements: []const TypeRefId,
        span: SourceSpan,
    };

    pub const FnType = struct {
        params: []const TypeRefId,
        return_type: TypeRefId,
        span: SourceSpan,
    };

    pub const OptionalType = struct {
        inner: TypeRefId,
        span: SourceSpan,
    };

    pub const MissingType = struct {
        span: SourceSpan,
    };
};

pub const AstPattern = union(enum) {
    identifier: IdentifierPattern,
    wildcard: WildcardPattern,
    literal: LiteralPattern,
    tuple: TuplePattern,
    path: PathPattern,
    missing: MissingPattern,

    pub const IdentifierPattern = struct {
        name: SymbolId,
        mutable: bool,
        span: SourceSpan,
    };

    pub const WildcardPattern = struct {
        span: SourceSpan,
    };

    pub const LiteralPattern = struct {
        value: ExprId,
        span: SourceSpan,
    };

    pub const TuplePattern = struct {
        elements: []const PatId,
        span: SourceSpan,
    };

    pub const PathPattern = struct {
        path: SymbolId,
        span: SourceSpan,
    };

    pub const MissingPattern = struct {
        span: SourceSpan,
    };
};

pub const ParamDef = struct {
    name: SymbolId,
    type_ref: ?TypeRefId,
    span: SourceSpan,
};

pub const FieldDef = struct {
    name: SymbolId,
    type_ref: TypeRefId,
    visibility: Visibility,
    span: SourceSpan,
};

pub const VariantDef = struct {
    name: SymbolId,
    fields: []const FieldDef,
    span: SourceSpan,
};

pub const Visibility = enum {
    public,
    private,
    package,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    and_,
    or_,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    shl,
    shr,
    assign,
    assign_add,
    assign_sub,
    assign_mul,
    assign_div,
    assign_mod,
    assign_and,
    assign_or,
    assign_xor,
    assign_shl,
    assign_shr,
    range,
    range_inclusive,
};

pub const UnaryOp = enum {
    negate,
    not,
    bitwise_not,
    deref,
    address,
    ref,
};

pub const LiteralKind = enum {
    integer,
    float,
    string,
    char,
    byte,
    byte_string,
    boolean,
    null_value,
};

pub const AstItem = union(enum) {
    function: AstDecl.FnDecl,
    struct_item: AstDecl.StructDecl,
    enum_item: AstDecl.EnumDecl,
    trait_item: AstDecl.TraitDecl,
    impl_item: AstDecl.ImplDecl,
    type_item: AstDecl.TypeAliasDecl,
    import_item: AstDecl.ImportDecl,
    module_item: AstDecl.ModuleDecl,
    statement: StmtId,
};
