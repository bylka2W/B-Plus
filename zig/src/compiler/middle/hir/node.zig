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

    pub fn deinit(self: *Expr, alloc: Allocator) void {
        switch (self.*) {
            .binary => |b| {
                b.left.deinit(alloc);
                alloc.destroy(b.left);
                b.right.deinit(alloc);
                alloc.destroy(b.right);
            },
            .unary => |u| {
                u.operand.deinit(alloc);
                alloc.destroy(u.operand);
            },
            .call => |c| {
                alloc.free(c.name);
                alloc.free(c.args);
            },
            else => {},
        }
    }

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

    pub fn deinit(self: *HirBlock, alloc: Allocator) void {
        alloc.free(self.label);
        for (self.stmts.items) |*s| {
            switch (s.*) {
                .return_stmt => |*r| {
                    if (r.*) |*e| e.deinit(alloc);
                },
                .var_decl => |*v| {
                    alloc.free(v.name);
                    if (v.init) |*i| i.deinit(alloc);
                },
                .assign => |*a| {
                    alloc.free(a.name);
                    a.value.deinit(alloc);
                },
                .expr_stmt => |*e| e.deinit(alloc),
                else => {},
            }
        }
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

// ── METAL: GPU kernel / entry / binding nodes ──

pub const HirKernel = struct {
    name: []const u8,
    entries: std.ArrayList(HirEntry),
    bindings: std.ArrayList(HirBinding),
    numthreads: struct { x: u32, y: u32, z: u32 },
    context_vars: std.ArrayList(HirContextVar),

    pub const HirContextVar = struct {
        name: []const u8,
        ty: TypeId,
    };
};

pub const HirEntry = struct {
    name: []const u8,
    params: std.ArrayList(EntryParam),
    body: HirBlock,
    return_type: TypeId,

    pub const EntryParam = struct {
        name: []const u8,
        builtin: ?[]const u8,
        ty: TypeId,
    };
};

pub const HirBinding = struct {
    name: []const u8,
    binding_type: BindingType,
    slot: u32,
    format: TypeId,

    pub const BindingType = enum {
        texture2d,
        rw_texture2d,
        sampler,
        structured_buffer,
        constant_buffer,
    };
};

pub const HirAttr = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const HirModule = struct {
    allocator: Allocator,
    functions: std.ArrayList(HirFunction),
    states: std.ArrayList(HirState),
    kernels: std.ArrayList(HirKernel),

    pub fn init(allocator: Allocator) HirModule {
        return .{
            .allocator = allocator,
            .functions = std.ArrayList(HirFunction).init(allocator),
            .states = std.ArrayList(HirState).init(allocator),
            .kernels = std.ArrayList(HirKernel).init(allocator),
        };
    }

    pub fn deinit(self: *HirModule) void {
        for (self.functions.items) |*f| {
            self.allocator.free(f.name);
            for (f.params.items) |p| self.allocator.free(p.name);
            f.params.deinit();
            f.body.deinit(self.allocator);
        }
        self.functions.deinit();
        for (self.states.items) |*s| {
            self.allocator.free(s.name);
            for (s.variables.items) |v| self.allocator.free(v.name);
            s.variables.deinit();
            for (s.transitions.items) |t| {
                if (t.event) |e| self.allocator.free(e);
                self.allocator.free(t.target);
            }
            s.transitions.deinit();
            if (s.enter_body) |*b| b.deinit(self.allocator);
            if (s.exit_body) |*b| b.deinit(self.allocator);
        }
        self.states.deinit();
        for (self.kernels.items) |*k| {
            self.allocator.free(k.name);
            for (k.entries.items) |*e| {
                self.allocator.free(e.name);
                for (e.params.items) |*p| {
                    self.allocator.free(p.name);
                    if (p.builtin) |b| self.allocator.free(b);
                }
                e.params.deinit();
                e.body.deinit(self.allocator);
            }
            k.entries.deinit();
            for (k.bindings.items) |*b| self.allocator.free(b.name);
            k.bindings.deinit();
            for (k.context_vars.items) |*cv| self.allocator.free(cv.name);
            k.context_vars.deinit();
        }
        self.kernels.deinit();
    }
};
