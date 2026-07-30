const std = @import("std");
const Allocator = std.mem.Allocator;
const ids = @import("../../frontend/foundation/ids/ids.zig");
const SourceSpan = @import("../../frontend/source/location/span.zig").SourceSpan;

pub const ThirId = ids.ThirId;
pub const DefId = ids.DefId;
pub const SymbolId = ids.SymbolId;
pub const TypeId = ids.TypeId;
pub const ExprId = ids.ExprId;
pub const StmtId = ids.StmtId;
pub const LabelId = ids.LabelId;

pub const ValueId = ids.ThirValueId;
pub const BlockId = ids.ThirBlockId;
pub const PlaceId = ids.ThirPlaceId;

pub const NO_VALUE = ValueId.INVALID;
pub const INVALID_BLOCK = BlockId.INVALID;

// ─── Literals ───
pub const Literal = union(enum) {
    int: i64,
    float: f64,
    bool_val: bool,
    string: []const u8,
    unit: void,
};

// ─── Binary operations ───
pub const BinOp = enum {
    add, sub, mul, div, mod,
    eq, ne, lt, le, gt, ge,
    and_, or_,
    bitwise_and, bitwise_or, bitwise_xor, shl, shr,
};

// ─── Unary operations ───
pub const UnOp = enum {
    negate, not, bitwise_not,
};

// ─── Cast kinds ───
pub const CastKind = enum {
    int_extend_signed,
    int_extend_unsigned,
    int_truncate,
    int_to_float,
    uint_to_float,
    float_to_int,
    float_to_uint,
    float_extend,
    float_truncate,
    bool_to_int,
    int_to_bool,
    pointer_cast,
    pointer_to_int,
    int_to_pointer,
    bitcast,
    unsize,
};

// ─── Storage class ───
pub const Storage = enum {
    stack,
    local_reg,
    spill,
};

// ─── Value definition site ───
pub const ValueDef = struct {
    ty: TypeId,
    storage: Storage,
    expr: ExprId = ExprId.INVALID,
    def_block: BlockId = INVALID_BLOCK,
    span: SourceSpan = .{},
};

// ─── Place descriptor (for let-binding storage) ───
pub const PlaceDesc = struct {
    ty: TypeId,
    storage: Storage,
    mutable: bool,
    span: SourceSpan,
};

// ─── Place (lvalue) ───
pub const Place = struct {
    local: ValueId,
    projections: []const Projection,

    pub const Projection = union(enum) {
        field: u32,
        index: ValueId,
        deref: void,
        downcast: u32,
    };
};

pub const ThirCase = struct {
    value: i64,
    target: BlockId,
};

// ─── THIR Expressions ───
pub const ThirExpr = struct {
    span: SourceSpan,
    ty: TypeId,
    kind: Kind,

    pub const Kind = union(enum) {
        none: void,
        literal: Literal,
        load: LoadExpr,
        store: StoreExpr,
        binary: BinaryExpr,
        unary: UnaryExpr,
        cast: CastExpr,
        call: CallExpr,
        field_addr: FieldAddrExpr,
        index_addr: IndexAddrExpr,
        aggregate: AggregateExpr,
        array_repeat: ArrayRepeatExpr,
        addr_of: AddrOfExpr,
        deref: DerefExpr,
        branch: BranchExpr,
        switch_expr: SwitchExpr,
        loop: LoopExpr,
        return_val: ReturnExpr,
        break_val: BreakExpr,
        continue_val: ContinueExpr,
        unreachable_val: void,
        unit: void,
    };

    pub const LoadExpr = struct {
        place: Place,
    };

    pub const StoreExpr = struct {
        place: Place,
        value: ValueId,
    };

    pub const BinaryExpr = struct {
        op: BinOp,
        lhs: ValueId,
        rhs: ValueId,
    };

    pub const UnaryExpr = struct {
        op: UnOp,
        operand: ValueId,
    };

    pub const CastExpr = struct {
        kind: CastKind,
        operand: ValueId,
        from_ty: TypeId,
        to_ty: TypeId,
    };

    pub const CallExpr = struct {
        func: Callee,
        args: []const ValueId,
        ret_ty: TypeId,
    };

    pub const Callee = union(enum) {
        function: DefId,
        value: ValueId,
    };

    pub const FieldAddrExpr = struct {
        object: ValueId,
        field_index: u32,
    };

    pub const IndexAddrExpr = struct {
        object: ValueId,
        index: ValueId,
    };

    pub const AggregateExpr = struct {
        fields: []const ValueId,
    };

    pub const ArrayRepeatExpr = struct {
        value: ValueId,
        count: u32,
    };

    pub const AddrOfExpr = struct {
        operand: ValueId,
        mut: bool,
    };

    pub const DerefExpr = struct {
        operand: ValueId,
    };

    pub const BranchExpr = struct {
        then_block: BlockId,
    };

    pub const SwitchExpr = struct {
        scrutinee: ValueId,
        cases: []const ThirCase,
        default: ?BlockId,
    };

    pub const LoopExpr = struct {
        body: BlockId,
        break_block: ?BlockId,
    };

    pub const ReturnExpr = struct {
        value: ?ValueId,
    };

    pub const BreakExpr = struct {
        value: ?ValueId,
        target_loop: BlockId,
    };

    pub const ContinueExpr = struct {
        target_loop: BlockId,
    };
};

// ─── THIR Statements ───
pub const ThirStmt = struct {
    span: SourceSpan,
    kind: Kind,

    pub const Kind = union(enum) {
        let: LetStmt,
        assignment: AssignStmt,
        expr_stmt: ExprStmt,
        if_stmt: IfStmt,
        while_stmt: WhileStmt,
        return_stmt: ReturnStmt,
        break_stmt: BreakStmt,
        continue_stmt: ContinueStmt,
        block: BlockStmt,
    };

    pub const LetStmt = struct {
        place: ValueId,
        init: ValueId,
        storage: Storage,
    };

    pub const AssignStmt = struct {
        place: ValueId,
        value: ValueId,
    };

    pub const ExprStmt = struct {
        expr: ValueId,
    };

    pub const IfStmt = struct {
        cond: ValueId,
        then_block: BlockId,
        else_block: ?BlockId,
    };

    pub const WhileStmt = struct {
        cond_block: BlockId,
        body_block: BlockId,
        exit_block: BlockId,
    };

    pub const ReturnStmt = struct {
        value: ?ValueId,
    };

    pub const BreakStmt = struct {
        value: ?ValueId,
        target_loop: BlockId,
    };

    pub const ContinueStmt = struct {
        target_loop: BlockId,
    };

    pub const BlockStmt = struct {
        block: BlockId,
    };
};

// ─── Basic Block ───
pub const BasicBlock = struct {
    label: []const u8,
    stmts: []const ThirStmt,
    terminator: Terminator,

    pub const Terminator = union(enum) {
        br: BlockId,
        cond_br: struct {
            cond: ValueId,
            then: BlockId,
            else_: BlockId,
        },
        switch_br: struct {
            scrutinee: ValueId,
            cases: []const ThirCase,
            default: ?BlockId,
        },
        return_ret: struct {
            value: ?ValueId,
        },
        unreachable_term: void,
        diverge: void,
    };
};

// ─── THIR Function ───
pub const ThirFunction = struct {
    name: SymbolId,
    name_str: []const u8,
    def_id: DefId,
    params: []const Param,
    return_type: TypeId,
    body: ?Body,
    linkage: Linkage,

    pub const Param = struct {
        name: SymbolId,
        def_id: DefId,
        ty: TypeId,
        storage: Storage,
    };

    pub const Body = struct {
        blocks: []const BasicBlock,
        entry: BlockId,
        values: []const ValueDef,
        exprs: []const ThirExpr,
        places: []const PlaceDesc,
    };

    pub const Linkage = enum {
        @"export",
        internal,
        entry,
    };
};

// ─── THIR Struct ───
pub const ThirStruct = struct {
    name: SymbolId,
    def_id: DefId,
    fields: []const Field,

    pub const Field = struct {
        name: SymbolId,
        ty: TypeId,
    };
};

// ─── THIR Enum ───
pub const ThirEnum = struct {
    name: SymbolId,
    def_id: DefId,
    variants: []const Variant,

    pub const Variant = struct {
        name: SymbolId,
        fields: []const ThirStruct.Field,
        tag: u32,
    };
};

// ─── THIR Module ───
pub const ThirModule = struct {
    allocator: Allocator,
    functions: std.ArrayList(ThirFunction),
    structs: std.ArrayList(ThirStruct),
    enums: std.ArrayList(ThirEnum),
    next_value: u32,

    pub fn init(allocator: Allocator) ThirModule {
        return .{
            .allocator = allocator,
            .functions = std.ArrayList(ThirFunction).init(allocator),
            .structs = std.ArrayList(ThirStruct).init(allocator),
            .enums = std.ArrayList(ThirEnum).init(allocator),
            .next_value = 0,
        };
    }

    pub fn deinit(self: *ThirModule) void {
        self.functions.deinit();
        self.structs.deinit();
        self.enums.deinit();
    }

    pub fn addFunction(self: *ThirModule, func: ThirFunction) !u32 {
        const idx: u32 = @intCast(self.functions.items.len);
        try self.functions.append(func);
        return idx;
    }

    pub fn allocValue(self: *ThirModule) ValueId {
        const id = self.next_value;
        self.next_value += 1;
        return ValueId.new(id);
    }

    pub fn getFunction(self: *ThirModule, idx: u32) *ThirFunction {
        return &self.functions.items[idx];
    }
};
