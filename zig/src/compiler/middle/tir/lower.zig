const std = @import("std");
const Allocator = std.mem.Allocator;
const tir = @import("types.zig");
const hir_mod = @import("hir_view.zig");
const hir_types = hir_mod;
const HIRExpr = hir_mod.Expr;
const HIRStmt = hir_mod.Stmt;
const HIRBinOp = hir_mod.BinOp;

const LowerError = error{ TypeError, UnknownExpression, OutOfMemory };

pub fn lowerModule(allocator: Allocator, hir_module: *const hir_mod.HirModule) !tir.Module {
    var module = tir.Module.init(allocator);
    errdefer module.deinit();
    try ensureBuiltins(&module);

    for (hir_module.functions.items) |func| {
        try lowerFunction(&module, func);
    }
    for (hir_module.states.items) |state| {
        try lowerState(&module, state);
    }
    return module;
}

var t_void: tir.TypeId = tir.INVALID_TYPE;
var t_i1: tir.TypeId = tir.INVALID_TYPE;
var t_i8: tir.TypeId = tir.INVALID_TYPE;
var t_i16: tir.TypeId = tir.INVALID_TYPE;
var t_i32: tir.TypeId = tir.INVALID_TYPE;
var t_i64: tir.TypeId = tir.INVALID_TYPE;
var t_u8: tir.TypeId = tir.INVALID_TYPE;
var t_u16: tir.TypeId = tir.INVALID_TYPE;
var t_u32: tir.TypeId = tir.INVALID_TYPE;
var t_u64: tir.TypeId = tir.INVALID_TYPE;
var t_f32: tir.TypeId = tir.INVALID_TYPE;
var t_f64: tir.TypeId = tir.INVALID_TYPE;
var t_ptr: tir.TypeId = tir.INVALID_TYPE;

fn ensureBuiltins(module: *tir.Module) !void {
    if (t_void == tir.INVALID_TYPE) {
        t_void = try module.types.voidType();
        t_i1 = try module.types.scalarType(.i1);
        t_i8 = try module.types.scalarType(.i8);
        t_i16 = try module.types.scalarType(.i16);
        t_i32 = try module.types.scalarType(.i32);
        t_i64 = try module.types.scalarType(.i64);
        t_u8 = try module.types.scalarType(.u8);
        t_u16 = try module.types.scalarType(.u16);
        t_u32 = try module.types.scalarType(.u32);
        t_u64 = try module.types.scalarType(.u64);
        t_f32 = try module.types.scalarType(.f32);
        t_f64 = try module.types.scalarType(.f64);
        t_ptr = try module.types.pointerType(0, .generic);
    }
}

fn mapHirType(module: *tir.Module, ty: hir_types.TypeId) !tir.TypeId {
    return switch (ty) {
        .void => t_void,
        .bool_type => t_i1,
        .i8_type => t_i8,
        .i16_type => t_i16,
        .i32_type => t_i32,
        .i64_type => t_i64,
        .u8_type => t_u8,
        .u16_type => t_u16,
        .u32_type => t_u32,
        .u64_type => t_u64,
        .f32_type => t_f32,
        .f64_type => t_f64,
        .string_type => t_ptr,
        .ptr_type => t_ptr,
        .struct_type => t_ptr,
        .enum_type => t_i64,
        .invalid => t_void,
        _ => t_ptr,
    };
}

fn lowerFunction(module: *tir.Module, func: *const hir_mod.HirFunction) !void {
    try ensureBuiltins(module);
    const ret_type = try mapHirType(module, func.return_type);
    const linkage: tir.Function.Linkage = switch (func.linkage) {
        .@"export" => .@"export",
        .internal => .internal,
        .entry => .entry,
    };
    const fid = try module.addFunction(func.name, ret_type, linkage);

    {
        const fn_mut = module.getFunctionMut(fid);
        const owned_params = try module.allocator.alloc(tir.FuncParam, func.params.items.len);
        const owned_values = try module.allocator.alloc(tir.ValueId, func.params.items.len);
        for (func.params.items, 0..) |param, i| {
            owned_params[i] = .{
                .name = try module.allocator.dupe(u8, param.name),
                .ty = try mapHirType(module, param.ty),
            };
            owned_values[i] = try fn_mut.createValue(try mapHirType(module, param.ty));
        }
        fn_mut.params = owned_params;
        fn_mut.param_values = owned_values;
    }

    const entry_id = try module.getFunctionMut(fid).addBlock("entry");
    var ctx = Builder{
        .mod = module,
        .fid = fid,
        .blk = entry_id,
    };

    for (func.body.stmts.items) |stmt| {
        try lowerStmt(&ctx, stmt);
    }
    if (!ctx.terminated()) {
        _ = try ctx.emitOp(.ret, t_void, &.{}, .{ .none = {} });
    }
}

fn lowerState(module: *tir.Module, state: *const hir_mod.HirState) !void {
    try ensureBuiltins(module);
    const nm = try std.fmt.allocPrint(module.allocator, "state_{s}_entry", .{state.name});
    defer module.allocator.free(nm);
    const fid = try module.addFunction(nm, t_void, .entry);
    const entry_id = try module.getFunctionMut(fid).addBlock("entry");
    var ctx = Builder{
        .mod = module,
        .fid = fid,
        .blk = entry_id,
    };

    for (state.variables.items) |v| {
        const vt = try mapHirType(module, v.ty);
        _ = try ctx.emitOp(.alloca, vt, &.{}, .{ .none = {} });
        if (v.default) |dv| {
            const val = try lowerExpr(&ctx, dv);
            if (val != tir.NO_VALUE) {
                _ = try ctx.emitOp(.store, vt, &.{ val, val }, .{ .none = {} });
            }
        }
    }
    if (state.enter_body) |*body| {
        for (body.stmts.items) |stmt| {
            try lowerStmt(&ctx, stmt);
        }
    }
    if (!ctx.terminated()) {
        _ = try ctx.emitOp(.ret, t_void, &.{}, .{ .none = {} });
    }
}

const Builder = struct {
    mod: *tir.Module,
    fid: tir.FuncId,
    blk: tir.BlockId,

    fn terminated(self: *Builder) bool {
        const bl = self.mod.getFunctionMut(self.fid).blocks.items[self.blk];
        if (bl.instrs.items.len == 0) return false;
        const last = bl.instrs.items[bl.instrs.items.len - 1];
        return last.op == .ret or last.op == .br or last.op == .cond_br;
    }

    fn emitOp(self: *Builder, op: tir.Op, ty: tir.TypeId, ops: []const tir.ValueId, data: tir.Instruction.Data) !tir.ValueId {
        if (op == .ret or op == .br or op == .cond_br) {
            const owned_ops = if (ops.len > 0) try self.mod.allocator.dupe(tir.ValueId, ops) else &[_]tir.ValueId{};
            const inst = tir.Instruction{
                .op = op,
                .ty = ty,
                .result = tir.NO_VALUE,
                .operands = owned_ops,
                .data = data,
            };
            const fn_mut = self.mod.getFunctionMut(self.fid);
            try fn_mut.blocks.items[self.blk].instrs.append(inst);
            return tir.NO_VALUE;
        }
        const fn_mut = self.mod.getFunctionMut(self.fid);
        const result = try fn_mut.createValue(ty);
        const owned_ops = if (ops.len > 0) try self.mod.allocator.dupe(tir.ValueId, ops) else &[_]tir.ValueId{};
        const inst = tir.Instruction{
            .op = op,
            .ty = ty,
            .result = result,
            .operands = owned_ops,
            .data = data,
        };
        try fn_mut.blocks.items[self.blk].instrs.append(inst);
        return result;
    }

    fn emitStore(self: *Builder, ty: tir.TypeId, slot: tir.ValueId, val: tir.ValueId) !tir.ValueId {
        return self.emitOp(.store, ty, &.{ slot, val }, .{ .none = {} });
    }

    fn emitLoad(self: *Builder, slot: tir.ValueId, ty: tir.TypeId) !tir.ValueId {
        return self.emitOp(.load, ty, &.{slot}, .{ .none = {} });
    }

    fn emitAlloca(self: *Builder, ty: tir.TypeId) !tir.ValueId {
        return self.emitOp(.alloca, ty, &.{}, .{ .none = {} });
    }

    fn emitConstInt(self: *Builder, v: i64) !tir.ValueId {
        return self.emitOp(.const_int, t_i64, &.{}, .{ .const_data = .{ .int = v } });
    }

    fn emitConstBool(self: *Builder, v: bool) !tir.ValueId {
        return self.emitOp(.const_bool, t_i1, &.{}, .{ .const_data = .{ .bool_val = v } });
    }

    fn emitBinOp(self: *Builder, op: tir.Op, ty: tir.TypeId, l: tir.ValueId, r: tir.ValueId) !tir.ValueId {
        return self.emitOp(op, ty, &.{ l, r }, .{ .none = {} });
    }

    fn emitCall(self: *Builder, name: []const u8, ret_ty: tir.TypeId, args: []const tir.ValueId) !tir.ValueId {
        const owned_name = try self.mod.allocator.dupe(u8, name);
        const owned_args = if (args.len > 0) try self.mod.allocator.dupe(tir.ValueId, args) else &[_]tir.ValueId{};
        return self.emitOp(.call, ret_ty, &.{}, .{ .named_call = .{ .name = owned_name, .args = owned_args } });
    }

    fn newBlock(self: *Builder, label: []const u8) !tir.BlockId {
        return self.mod.getFunctionMut(self.fid).addBlock(label);
    }

    fn emitBr(self: *Builder, target: tir.BlockId) !void {
        _ = try self.emitOp(.br, t_void, &.{}, .{ .block_target = target });
    }

    fn emitCondBr(self: *Builder, cond: tir.ValueId, then_b: tir.BlockId, else_b: tir.BlockId) !void {
        _ = try self.emitOp(.cond_br, t_void, &.{cond}, .{ .cond_branch = .{ .cond = cond, .then_block = then_b, .else_block = else_b } });
    }

    fn emitRet(self: *Builder, val: tir.ValueId, ty: tir.TypeId) !void {
        if (val != tir.NO_VALUE) {
            _ = try self.emitOp(.ret, ty, &.{val}, .{ .none = {} });
        } else {
            _ = try self.emitOp(.ret, t_void, &.{}, .{ .none = {} });
        }
    }

    fn retVoid(self: *Builder) !void {
        _ = try self.emitOp(.ret, t_void, &.{}, .{ .none = {} });
    }
};

fn lowerStmt(ctx: *Builder, stmt: HIRStmt) anyerror!void {
    if (ctx.terminated()) return;

    switch (stmt) {
        .return_stmt => |opt_expr| {
            if (opt_expr) |expr| {
                const val = try lowerExpr(ctx, expr);
                const ty = inferExprType(expr);
                try ctx.emitRet(val, ty);
            } else {
                try ctx.retVoid();
            }
        },
        .var_decl => |vd| {
            const vt = try mapHirType(ctx.mod, vd.ty);
            const slot = try ctx.emitAlloca(vt);
            _ = slot;
            if (vd.init) |init| {
                const val = try lowerExpr(ctx, init);
                if (val != tir.NO_VALUE) {
                    _ = try ctx.emitStore(vt, slot, val);
                }
            }
        },
        .assign => |a| {
            const val = try lowerExpr(ctx, a.value);
            if (val != tir.NO_VALUE) {
                const ty = inferExprType(a.value);
                _ = try ctx.emitStore(ty, val, val);
            }
        },
        .if_stmt => |is| {
            const cond_val = try lowerExpr(ctx, is.cond);
            if (cond_val == tir.NO_VALUE) return;

            const then_id = try ctx.newBlock("if_then");
            const else_id = try ctx.newBlock("if_else");
            const merge_id = try ctx.newBlock("if_merge");

            try ctx.emitCondBr(cond_val, then_id, else_id);

            ctx.blk = then_id;
            for (is.then_body) |s| try lowerStmt(ctx, s);
            if (!ctx.terminated()) try ctx.emitBr(merge_id);

            ctx.blk = else_id;
            if (is.else_body) |else_body| {
                for (else_body) |s| try lowerStmt(ctx, s);
            }
            if (!ctx.terminated()) try ctx.emitBr(merge_id);

            ctx.blk = merge_id;
        },
        .while_stmt => |ws| {
            const header_id = try ctx.newBlock("while_header");
            const body_id = try ctx.newBlock("while_body");
            const exit_id = try ctx.newBlock("while_exit");

            try ctx.emitBr(header_id);
            ctx.blk = header_id;
            const cond_val = try lowerExpr(ctx, ws.cond);
            if (cond_val == tir.NO_VALUE) return;
            try ctx.emitCondBr(cond_val, body_id, exit_id);

            ctx.blk = body_id;
            for (ws.body) |s| try lowerStmt(ctx, s);
            if (!ctx.terminated()) try ctx.emitBr(header_id);

            ctx.blk = exit_id;
        },
        .expr_stmt => |expr| {
            _ = try lowerExpr(ctx, expr);
        },
    }
}

fn lowerExpr(ctx: *Builder, expr: HIRExpr) anyerror!tir.ValueId {
    switch (expr) {
        .literal_int => |v| return ctx.emitConstInt(v),
        .literal_bool => |v| return ctx.emitConstBool(v),
        .literal_string => |_| return ctx.emitConstInt(0),
        .variable => |_| return tir.NO_VALUE,
        .binary => |b| {
            const l = try lowerExpr(ctx, b.left.*);
            const r = try lowerExpr(ctx, b.right.*);
            if (l == tir.NO_VALUE or r == tir.NO_VALUE) return tir.NO_VALUE;
            const op = mapBinOp(b.op);
            const ty = inferExprType(expr);
            return ctx.emitBinOp(op, ty, l, r);
        },
        .unary => |u| {
            const val = try lowerExpr(ctx, u.operand.*);
            if (val == tir.NO_VALUE) return tir.NO_VALUE;
            if (u.op == .neg) {
                const zero = try ctx.emitConstInt(0);
                return ctx.emitBinOp(.sub, t_i64, zero, val);
            }
            return tir.NO_VALUE;
        },
        .call => |c| {
            var args = std.ArrayList(tir.ValueId).init(ctx.mod.allocator);
            defer args.deinit();
            for (c.args) |arg| {
                const v = try lowerExpr(ctx, arg);
                if (v != tir.NO_VALUE) try args.append(v);
            }
            return ctx.emitCall(c.name, t_void, args.items);
        },
    }
}

fn mapBinOp(op: HIRBinOp) tir.Op {
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
        .@"and" => .and_op,
        .@"or" => .or_op,
    };
}

fn inferExprType(expr: HIRExpr) tir.TypeId {
    return switch (expr) {
        .literal_int => t_i64,
        .literal_bool => t_i1,
        .literal_string => t_ptr,
        .variable => t_i64,
        .binary => |b| {
            const lty = inferExprType(b.left.*);
            const rty = inferExprType(b.right.*);
            switch (b.op) {
                .eq, .ne, .lt, .gt, .le, .ge, .@"and", .@"or" => t_i1,
                else => {
                    if (lty == t_f64 or rty == t_f64) return t_f64;
                    if (lty == t_f32 or rty == t_f32) return t_f32;
                    return t_i64;
                },
            }
        },
        .unary => |u| inferExprType(u.operand.*),
        .call => t_void,
    };
}
