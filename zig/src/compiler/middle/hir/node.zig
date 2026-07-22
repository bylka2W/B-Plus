const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const TypeId = types.TypeId;

pub const Expr = union(enum) {
    literal_int: i64,
    literal_bool: bool,
    literal_string: []const u8,
    variable: []const u8,
    binary: BinaryExpr,
    unary: UnaryExpr,
    call: CallExpr,

    pub const BinaryExpr = struct {
        op: BinOp,
        left: *Expr,
        right: *Expr,
    };

    pub const UnaryExpr = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const CallExpr = struct {
        name: []const u8,
        args: []const Expr,
    };
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    @"and",
    @"or",
};

pub const UnaryOp = enum {
    neg,
    not,
};

pub const Stmt = union(enum) {
    return_stmt: ?Expr,
    var_decl: VarDecl,
    assign: Assign,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    expr_stmt: Expr,

    pub const VarDecl = struct {
        name: []const u8,
        ty: TypeId,
        init: ?Expr,
    };

    pub const Assign = struct {
        name: []const u8,
        value: Expr,
    };

    pub const IfStmt = struct {
        cond: Expr,
        then_body: []const Stmt,
        else_body: ?[]const Stmt,
    };

    pub const WhileStmt = struct {
        cond: Expr,
        body: []const Stmt,
    };
};

pub const HirBlock = struct {
    label: []const u8,
    stmts: std.ArrayList(Stmt),

    pub fn deinit(self: *HirBlock, allocator: Allocator) void {
        self.stmts.deinit();
    }
};

pub const HirFunction = struct {
    name: []const u8,
    params: std.ArrayList(types.FuncParam),
    body: HirBlock,
    return_type: TypeId,
    linkage: Linkage,

    pub const Linkage = enum { @"export", internal, entry };
};

pub const HirState = struct {
    name: []const u8,
    variables: std.ArrayList(StateVar),
    enter_body: ?HirBlock,
    exit_body: ?HirBlock,
    transitions: std.ArrayList(Transition),

    pub const StateVar = struct {
        name: []const u8,
        ty: TypeId,
        default: ?Expr,
    };

    pub const Transition = struct {
        event: ?[]const u8,
        target: []const u8,
        guard: ?Expr,
        weight: ?f64,
    };
};

pub const HirModule = struct {
    allocator: Allocator,
    functions: std.ArrayList(HirFunction),
    states: std.ArrayList(HirState),

    pub fn init(allocator: Allocator) HirModule {
        return .{
            .allocator = allocator,
            .functions = std.ArrayList(HirFunction).init(allocator),
            .states = std.ArrayList(HirState).init(allocator),
        };
    }

    pub fn deinit(self: *HirModule) void {
        for (self.functions.items) |*f| {
            self.allocator.free(f.name);
            f.body.deinit(self.allocator);
            f.params.deinit();
        }
        self.functions.deinit();
        for (self.states.items) |*s| {
            self.allocator.free(s.name);
            s.variables.deinit();
            s.transitions.deinit();
            if (s.enter_body) |*b| b.deinit(self.allocator);
            if (s.exit_body) |*b| b.deinit(self.allocator);
        }
        self.states.deinit();
    }
};
