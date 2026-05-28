const std = @import("std");

pub const LiteralType = enum { int, float, string, boolean };

pub const Literal = struct {
    lit_type: LiteralType,
    int_val: i64 = 0,
    float_val: f64 = 0.0,
    string_val: []const u8 = "",
    bool_val: bool = false,
};

pub const Expr = struct {
    const Kind = enum {
        literal,
        ident,
        binary,
        unary,
        postfix,
        call,
    };
    kind: Kind,
    literal: Literal = .{ .lit_type = .int },
    ident: []const u8 = "",
    left: ?*Expr = null,
    right: ?*Expr = null,
    op: []const u8 = "",
    callee: []const u8 = "",
    args: std.ArrayList(*Expr) = undefined,
};

pub const Stmt = struct {
    const Kind = enum {
        print,
        return_stmt,
        expr_stmt,
        var_decl,
        assign,
        if_stmt,
        while_stmt,
        for_stmt,
        block,
    };
    kind: Kind,
    print_arg: ?*Expr = null,
    print_args: std.ArrayList(*Expr) = undefined,
    return_expr: ?*Expr = null,
    expr: ?*Expr = null,
    var_name: []const u8 = "",
    var_type: []const u8 = "",
    var_init: ?*Expr = null,
    assign_name: []const u8 = "",
    assign_op: []const u8 = "=",
    assign_expr: ?*Expr = null,
    condition: ?*Expr = null,
    then_body: std.ArrayList(Stmt) = undefined,
    else_body: std.ArrayList(Stmt) = undefined,
    stmts: std.ArrayList(Stmt) = undefined,
};

pub const VarDecl = struct {
    name: []const u8,
    var_type: []const u8,
    init: ?*Expr,
};

pub const ActionDecl = struct {
    action_type: []const u8, // "enter" or "exit"
    raw_body: []const u8 = "",
    body_stmts: std.ArrayList(Stmt),
};

pub const Transition = struct {
    event: []const u8,
    target: []const u8,
    guard: []const u8 = "",
    guard_stmts: std.ArrayList(Stmt) = undefined,
    body: []const u8,
    body_stmts: std.ArrayList(Stmt) = undefined,
};

pub const StateDecl = struct {
    name: []const u8,
    vars: std.ArrayList(VarDecl),
    actions: std.ArrayList(ActionDecl),
    transitions: std.ArrayList(Transition),
};

pub const Param = struct { name: []const u8, ptype: []const u8 };
pub const Field = struct { name: []const u8, ftype: []const u8 };

pub const FnDecl = struct {
    name: []const u8,
    is_inline: bool,
    return_type: []const u8,
    params: std.ArrayList(Param),
    body: []const u8,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: std.ArrayList(Field),
};

pub const EntryDecl = struct {
    name: []const u8,
    raw_body: []const u8 = "",
    body: std.ArrayList(Stmt),
};

pub const ComputeKernel = struct {
    name: []const u8,
    body: []const u8,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    entry: ?EntryDecl,
    start_state: []const u8 = "",
    context_vars: std.ArrayList(VarDecl),
    states: std.ArrayList(StateDecl),
    fns: std.ArrayList(FnDecl),
    structs: std.ArrayList(StructDecl),
    kernels: std.ArrayList(ComputeKernel),
};
