const std = @import("std");
const Allocator = std.mem.Allocator;

const frontend_ast = @import("../../frontend/ast.zig");
const hir_arena_mod = @import("../../frontend/hir/arena.zig");
const hir_item = @import("../../frontend/hir/item.zig");
const hir_expr = @import("../../frontend/hir/expr.zig");
const hir_stmt = @import("../../frontend/hir/stmt.zig");
const hir_body = @import("../../frontend/hir/body.zig");
const hir_literal = @import("../../frontend/hir/literal.zig");
const text_parse = @import("text_parse.zig");

pub const HirArena = hir_arena_mod.HirArena;
pub const HirArenaItem = hir_item.HirItem;
pub const HirArenaExpr = hir_expr.HirExpr;
pub const HirArenaStmt = hir_stmt.HirStmt;
pub const HirArenaBody = hir_body.HirBody;
pub const HirLiteral = hir_literal.HirLiteral;

pub const TypeId = enum(u32) {
    invalid = 0,
    void,
    bool_type,
    i8_type,
    i16_type,
    i32_type,
    i64_type,
    u8_type,
    u16_type,
    u32_type,
    u64_type,
    f32_type,
    f64_type,
    string_type,
    ptr_type,
    struct_type,
    enum_type,
    _,

    pub fn fromName(type_name: []const u8) TypeId {
        if (std.mem.eql(u8, type_name, "void")) return .void;
        if (std.mem.eql(u8, type_name, "bool")) return .bool_type;
        if (std.mem.eql(u8, type_name, "i8")) return .i8_type;
        if (std.mem.eql(u8, type_name, "i16")) return .i16_type;
        if (std.mem.eql(u8, type_name, "i32")) return .i32_type;
        if (std.mem.eql(u8, type_name, "i64") or std.mem.eql(u8, type_name, "int")) return .i64_type;
        if (std.mem.eql(u8, type_name, "u8")) return .u8_type;
        if (std.mem.eql(u8, type_name, "u16")) return .u16_type;
        if (std.mem.eql(u8, type_name, "u32")) return .u32_type;
        if (std.mem.eql(u8, type_name, "u64")) return .u64_type;
        if (std.mem.eql(u8, type_name, "f32")) return .f32_type;
        if (std.mem.eql(u8, type_name, "f64")) return .f64_type;
        if (std.mem.eql(u8, type_name, "string")) return .string_type;
        if (std.mem.eql(u8, type_name, "ptr")) return .ptr_type;
        return .invalid;
    }
};

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
    params: std.ArrayList(FuncParam),
    body: HirBlock,
    return_type: TypeId,
    linkage: Linkage,

    pub const Linkage = enum { @"export", internal, entry };
};

pub const FuncParam = struct {
    name: []const u8,
    ty: TypeId,
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

pub const SemaContext = struct {
    sema_result: ?*const @import("../../frontend/sema/sema.zig").SemaResult,

    pub fn empty() SemaContext {
        return .{ .sema_result = null };
    }

    pub fn fromResult(result: *const @import("../../frontend/sema/sema.zig").SemaResult) SemaContext {
        return .{ .sema_result = result };
    }
};

pub const LowerError = error{ ParseError, TypeNotFound, OutOfMemory };

fn mapFrontendBinOp(op: hir_expr.BinOp) BinOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .and_ => .@"and",
        .or_ => .@"or",
        else => .add,
    };
}

fn mapFrontendUnaryOp(op: hir_expr.UnaryOp) UnaryOp {
    return switch (op) {
        .negate => .neg,
        .not => .not,
        else => .neg,
    };
}

fn mapFrontendType(ty: hir_item.TypeId) TypeId {
    if (ty.index == 0) return .invalid;
    return switch (ty.index % 20) {
        1 => .void,
        2 => .bool_type,
        3 => .i8_type,
        4 => .i16_type,
        5 => .i32_type,
        6 => .i64_type,
        7 => .u8_type,
        8 => .u16_type,
        9 => .u32_type,
        10 => .u64_type,
        11 => .f32_type,
        12 => .f64_type,
        13 => .string_type,
        14 => .ptr_type,
        15 => .struct_type,
        16 => .enum_type,
        else => .invalid,
    };
}

fn materializeExpr(alloc: Allocator, arena: *const HirArena, expr_id: hir_item.ExprId) !Expr {
    if (!expr_id.isValid()) return .{ .literal_int = 0 };
    const arena_expr = arena.getExpr(expr_id) orelse return .{ .literal_int = 0 };

    return switch (arena_expr.kind) {
        .literal => |l| switch (l.value) {
            .int => |v| .{ .literal_int = v },
            .float => |v| {
                _ = v;
                return .{ .literal_int = 0 };
            },
            .boolean => |v| .{ .literal_bool = v },
            .string => |v| .{ .literal_string = try alloc.dupe(u8, v) },
        },
        .path => .{ .variable = try alloc.dupe(u8, "var") },
        .binary => |b| {
            const left_ptr = alloc.create(Expr) catch return error.OutOfMemory;
            left_ptr.* = try materializeExpr(alloc, arena, b.left);
            const right_ptr = alloc.create(Expr) catch return error.OutOfMemory;
            right_ptr.* = try materializeExpr(alloc, arena, b.right);
            return .{ .binary = .{ .op = mapFrontendBinOp(b.op), .left = left_ptr, .right = right_ptr } };
        },
        .unary => |u| {
            const operand_ptr = alloc.create(Expr) catch return error.OutOfMemory;
            operand_ptr.* = try materializeExpr(alloc, arena, u.operand);
            return .{ .unary = .{ .op = mapFrontendUnaryOp(u.op), .operand = operand_ptr } };
        },
        .call => |c| {
            var args = std.ArrayList(Expr).init(alloc);
            for (c.args) |arg_id| {
                args.append(try materializeExpr(alloc, arena, arg_id)) catch return error.OutOfMemory;
            }
            return .{ .call = .{ .name = try alloc.dupe(u8, "call"), .args = args.toOwnedSlice() catch return error.OutOfMemory } };
        },
        else => .{ .literal_int = 0 },
    };
}

fn materializeStmt(alloc: Allocator, arena: *const HirArena, stmt_id: hir_item.StmtId) !Stmt {
    if (!stmt_id.isValid()) return .{ .expr_stmt = .{ .literal_int = 0 } };
    const arena_stmt = arena.getStmt(stmt_id) orelse return .{ .expr_stmt = .{ .literal_int = 0 } };

    return switch (arena_stmt.kind) {
        .local_decl => |ld| {
            const init_val = if (ld.init) |init_id|
                try materializeExpr(alloc, arena, init_id)
            else
                null;
            return .{ .var_decl = .{
                .name = try alloc.dupe(u8, "local"),
                .ty = if (ld.type_annotation) |ta| mapFrontendType(ta) else .i64_type,
                .init = init_val,
            } };
        },
        .expr => |es| .{ .expr_stmt = try materializeExpr(alloc, arena, es.expr) },
        .return_stmt => |rs| {
            const val = if (rs.value) |v| try materializeExpr(alloc, arena, v) else null;
            return .{ .return_stmt = val };
        },
        .if_stmt => |is| {
            const cond = try materializeExpr(alloc, arena, is.condition);
            var then_stmts = std.ArrayList(Stmt).init(alloc);
            then_stmts.append(try materializeStmt(alloc, arena, is.then_branch)) catch return error.OutOfMemory;
            const else_stmts: ?[]const Stmt = if (is.else_branch) |eb| blk: {
                var list = std.ArrayList(Stmt).init(alloc);
                list.append(try materializeStmt(alloc, arena, eb)) catch return error.OutOfMemory;
                break :blk list.toOwnedSlice() catch return error.OutOfMemory;
            } else null;
            return .{ .if_stmt = .{
                .cond = cond,
                .then_body = then_stmts.toOwnedSlice() catch return error.OutOfMemory,
                .else_body = else_stmts,
            } };
        },
        .while_stmt => |ws| {
            const cond = try materializeExpr(alloc, arena, ws.condition);
            var body_stmts = std.ArrayList(Stmt).init(alloc);
            body_stmts.append(try materializeStmt(alloc, arena, ws.body)) catch return error.OutOfMemory;
            return .{ .while_stmt = .{
                .cond = cond,
                .body = body_stmts.toOwnedSlice() catch return error.OutOfMemory,
            } };
        },
        else => .{ .expr_stmt = .{ .literal_int = 0 } },
    };
}

fn materializeBlock(alloc: Allocator, arena: *const HirArena, body_id: hir_item.BodyId, label: []const u8) !HirBlock {
    var block = HirBlock{
        .label = try alloc.dupe(u8, label),
        .stmts = std.ArrayList(Stmt).init(alloc),
    };
    if (body_id.isValid()) {
        const body = arena.getBody(body_id) orelse return block;
        for (body.stmts) |stmt_id| {
            block.stmts.append(try materializeStmt(alloc, arena, stmt_id)) catch return error.OutOfMemory;
        }
    }
    return block;
}

pub fn buildModule(alloc: Allocator, arena: *const HirArena, program: *const frontend_ast.ProgramNode, sema_ctx: SemaContext) !HirModule {
    _ = arena;
    _ = sema_ctx;
    var module = HirModule.init(alloc);
    errdefer module.deinit();

    for (program.common.func_defs.items) |func| {
        var params = std.ArrayList(FuncParam).init(alloc);
        for (func.params.items) |p| {
            try params.append(.{
                .name = try alloc.dupe(u8, p.name),
                .ty = TypeId.fromName(p.type_name),
            });
        }

        var body = HirBlock{
            .label = try alloc.dupe(u8, "entry"),
            .stmts = std.ArrayList(Stmt).init(alloc),
        };

        for (func.body_lines.items) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (text_parse.parseStmt(alloc, trimmed)) |stmt| {
                try body.stmts.append(stmt);
            }
        }

        const ret_type = if (func.return_type) |rt| TypeId.fromName(rt) else .void;

        try module.functions.append(.{
            .name = try alloc.dupe(u8, func.name),
            .params = params,
            .body = body,
            .return_type = ret_type,
            .linkage = if (func.is_export) .@"export" else .internal,
        });
    }

    for (program.plan.states.items) |state| {
        var variables = std.ArrayList(HirState.StateVar).init(alloc);
        for (state.variables.items) |v| {
            const default_val: ?Expr = if (v.default_value) |dv|
                text_parse.parseExpr(alloc, dv)
            else
                null;
            try variables.append(.{
                .name = try alloc.dupe(u8, v.name),
                .ty = TypeId.fromName(v.type_name),
                .default = default_val,
            });
        }

        var transitions = std.ArrayList(HirState.Transition).init(alloc);
        for (state.transitions.items) |t| {
            try transitions.append(.{
                .event = if (t.event_name) |en| try alloc.dupe(u8, en) else null,
                .target = try alloc.dupe(u8, t.target),
                .guard = if (t.guard) |g| text_parse.parseExpr(alloc, g) else null,
                .weight = t.hot_weight,
            });
        }

        const enter_body = if (state.enter_body) |body_str| blk: {
            var block = HirBlock{
                .label = try alloc.dupe(u8, "enter"),
                .stmts = std.ArrayList(Stmt).init(alloc),
            };
            var pos: usize = 0;
            while (pos < body_str.len) {
                while (pos < body_str.len and (body_str[pos] == ' ' or body_str[pos] == '\t' or body_str[pos] == '\n' or body_str[pos] == '\r')) : (pos += 1) {}
                if (pos >= body_str.len) break;
                var end = pos;
                while (end < body_str.len and body_str[end] != ';') : (end += 1) {}
                const stmt_str = std.mem.trim(u8, body_str[pos..end], " \t\r\n");
                if (stmt_str.len > 0) {
                    if (text_parse.parseStmt(alloc, stmt_str)) |stmt| {
                        try block.stmts.append(stmt);
                    }
                }
                pos = end + 1;
            }
            break :blk block;
        } else null;

        try module.states.append(.{
            .name = try alloc.dupe(u8, state.name),
            .variables = variables,
            .enter_body = enter_body,
            .exit_body = null,
            .transitions = transitions,
        });
    }

    for (program.metal.kernels.items) |kernel| {
        const entries = std.ArrayList(HirEntry).init(alloc);
        const bindings = std.ArrayList(HirBinding).init(alloc);
        const context_vars = std.ArrayList(HirKernel.HirContextVar).init(alloc);

        var dispatch_x: u32 = 1;
        var dispatch_y: u32 = 1;
        var dispatch_z: u32 = 1;

        for (kernel.annotations.items) |ann| {
            const ann_name = std.mem.trim(u8, ann.name, " \t\r\n");
            if (std.mem.startsWith(u8, ann_name, "numthreads")) {
                if (ann.value) |val| {
                    var parts = std.mem.splitScalar(u8, val, ',');
                    if (parts.next()) |x_str| {
                        dispatch_x = std.fmt.parseInt(u32, std.mem.trim(u8, x_str, " \t"), 10) catch 1;
                    }
                    if (parts.next()) |y_str| {
                        dispatch_y = std.fmt.parseInt(u32, std.mem.trim(u8, y_str, " \t"), 10) catch 1;
                    }
                    if (parts.next()) |z_str| {
                        dispatch_z = std.fmt.parseInt(u32, std.mem.trim(u8, z_str, " \t"), 10) catch 1;
                    }
                }
            }
        }

        try module.kernels.append(.{
            .name = try alloc.dupe(u8, kernel.name),
            .entries = entries,
            .bindings = bindings,
            .numthreads = .{ .x = dispatch_x, .y = dispatch_y, .z = dispatch_z },
            .context_vars = context_vars,
        });
    }

    return module;
}
