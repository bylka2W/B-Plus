const std = @import("std");
const thir = @import("../thir.zig");
const ThirModule = thir.ThirModule;
const ThirFunction = thir.ThirFunction;
const ThirStmt = thir.ThirStmt;
const ThirExpr = thir.ThirExpr;
const BasicBlock = thir.BasicBlock;
const ThirValueId = thir.ValueId;
const ThirBlockId = thir.BlockId;
const ThirPlace = thir.Place;
const ThirCase = thir.ThirCase;
const ValueDef = thir.ValueDef;
const PlaceDesc = thir.PlaceDesc;
const Storage = thir.Storage;
const Literal = thir.Literal;
const BinOp = thir.BinOp;
const UnOp = thir.UnOp;
const CastKind = thir.CastKind;
const DefId = thir.DefId;
const SymbolId = thir.SymbolId;
const bir = @import("../../bir/bir.zig");
const bir_types = bir.types;
const BIRTypeId = bir_types.TypeId;
const ScalarKind = bir_types.ScalarKind;
const BIRValueId = bir.ValueId;
const BIRBlockId = bir.BlockId;
const Inst = bir.Inst;
const Op = bir.Op;
const PhiIncoming = bir.PhiIncoming;
const BIR_NO_VALUE = bir.NO_VALUE;
const type_sys = @import("../../../frontend/type_system/type_system.zig");
const TypeEngine = type_sys.TypeEngine;
const BuiltinKind = type_sys.BuiltinKind;

pub const LowerError = error{ TypeError, OutOfMemory };

pub const ThirToBir = struct {
    allocator: std.mem.Allocator,
    thir_mod: *ThirModule,
    engine: *TypeEngine,
    module: bir.Module,

    pub fn init(allocator: std.mem.Allocator, thir_mod: *ThirModule, engine: *TypeEngine) ThirToBir {
        return .{
            .allocator = allocator,
            .thir_mod = thir_mod,
            .engine = engine,
            .module = bir.Module.init(allocator),
        };
    }

    pub fn deinit(self: *ThirToBir) void {
        self.module.deinit();
    }

    pub fn lower(self: *ThirToBir) LowerError!bir.Module {
        try self.ensureBuiltinTypes();
        for (self.thir_mod.functions.items) |*func| {
            try self.lowerFunction(func);
        }
        const m = self.module;
        self.module = bir.Module.init(self.allocator);
        return m;
    }

    fn ensureBuiltinTypes(self: *ThirToBir) !void {
        _ = try self.module.types.voidType();
        _ = try self.module.types.scalarType(.i1);
        _ = try self.module.types.scalarType(.i8);
        _ = try self.module.types.scalarType(.i16);
        _ = try self.module.types.scalarType(.i32);
        _ = try self.module.types.scalarType(.i64);
        _ = try self.module.types.scalarType(.u8);
        _ = try self.module.types.scalarType(.u16);
        _ = try self.module.types.scalarType(.u32);
        _ = try self.module.types.scalarType(.u64);
        _ = try self.module.types.scalarType(.f32);
        _ = try self.module.types.scalarType(.f64);
        _ = try self.module.types.pointerType(0, .generic);
    }

    fn builtinToBir(self: *ThirToBir, kind: BuiltinKind) BIRTypeId {
        return switch (kind) {
            .bool_type => self.module.types.scalarType(.i1) catch 0,
            .i8_type => self.module.types.scalarType(.i8) catch 0,
            .i16_type => self.module.types.scalarType(.i16) catch 0,
            .i32_type => self.module.types.scalarType(.i32) catch 0,
            .i64_type => self.module.types.scalarType(.i64) catch 0,
            .u8_type => self.module.types.scalarType(.u8) catch 0,
            .u16_type => self.module.types.scalarType(.u16) catch 0,
            .u32_type => self.module.types.scalarType(.u32) catch 0,
            .u64_type => self.module.types.scalarType(.u64) catch 0,
            .f32_type => self.module.types.scalarType(.f32) catch 0,
            .f64_type => self.module.types.scalarType(.f64) catch 0,
            .void_type => self.module.types.voidType() catch 0,
            .never_type => self.module.types.voidType() catch 0,
            .str_type => self.module.types.pointerType(0, .generic) catch 0,
            .char_type => self.module.types.scalarType(.u8) catch 0,
        };
    }

    fn typeToBir(self: *ThirToBir, ty: type_sys.TypeId) BIRTypeId {
        const resolved = self.engine.resolve(ty);
        const data = self.engine.get(resolved) orelse return self.module.types.voidType() catch 0;
        return switch (data) {
            .builtin => |b| self.builtinToBir(b),
            .pointer => self.module.types.pointerType(0, .generic) catch 0,
            .slice => self.module.types.pointerType(0, .generic) catch 0,
            .array => |a| {
                const elem = self.typeToBir(a.element);
                return self.module.types.arrayType(elem, @intCast(a.length)) catch 0;
            },
            .fn_ptr => self.module.types.pointerType(0, .generic) catch 0,
            .tuple => self.module.types.pointerType(0, .generic) catch 0,
            .infer_var => self.module.types.voidType() catch 0,
            .resolved_var => |r| self.typeToBir(r),
            .never => self.module.types.voidType() catch 0,
            .unit => self.module.types.voidType() catch 0,
            else => self.module.types.pointerType(0, .generic) catch 0,
        };
    }

    fn lowerFunction(self: *ThirToBir, func: *ThirFunction) LowerError!void {
        const ret_ty = self.typeToBir(func.return_type);
        const owned_name = try std.fmt.allocPrint(self.allocator, "fn_{d}", .{func.def_id.index});
        defer self.allocator.free(owned_name);

        const cc: bir.CallingConvention = switch (func.linkage) {
            .@"export" => .entry,
            .entry => .entry,
            .internal => .internal,
        };

        const func_id = try self.module.addFunction(owned_name, ret_ty, cc);

        {
            const fn_mut = self.module.getFunctionMut(func_id);
            const owned_params = try self.allocator.alloc(bir.FuncParam, func.params.len);
            const owned_values = try self.allocator.alloc(BIRValueId, func.params.len);
            for (func.params, 0..) |param, i| {
                const param_ty = self.typeToBir(param.ty);
                owned_params[i] = .{
                    .name = try std.fmt.allocPrint(self.allocator, "param_{d}", .{param.def_id.index}),
                    .ty = param_ty,
                };
                owned_values[i] = try fn_mut.createValue();
            }
            fn_mut.params = owned_params;
            fn_mut.param_values = owned_values;
        }

        const body = func.body orelse return;

        var block_map = std.AutoHashMap(ThirBlockId, BIRBlockId).init(self.allocator);
        defer block_map.deinit();

        var value_map = std.AutoHashMap(ThirValueId, Builder.ValueBinding).init(self.allocator);
        defer value_map.deinit();

        var value_ty_map = std.AutoHashMap(ThirValueId, BIRTypeId).init(self.allocator);
        defer value_ty_map.deinit();

        for (body.blocks, 0..) |_, i| {
            const label = try std.fmt.allocPrint(self.allocator, "bb{d}", .{i});
            defer self.allocator.free(label);
            const bir_blk = try self.module.addBlock(func_id, label);
            try block_map.put(ThirBlockId.new(@intCast(i)), bir_blk);
        }

        var param_map = std.AutoHashMap(DefId, Builder.ValueBinding).init(self.allocator);
        defer param_map.deinit();

        for (func.params, 0..) |param, i| {
            try param_map.put(param.def_id, .{ .value = self.module.getFunction(func_id).param_values[i], .kind = .ssa });
        }

        for (body.values, 0..) |val_def, i| {
            const thir_vid = ThirValueId.new(@intCast(i));
            if (val_def.storage == .stack) {
                const slot_ty = self.typeToBir(val_def.ty);
                const entry_bir = block_map.get(body.entry) orelse 0;
                const slot = try self.module.addInst(func_id, entry_bir, try makeInst(self.allocator, .alloca, slot_ty, &.{}, .{ .none = {} }));
                try value_map.put(thir_vid, .{ .value = slot, .kind = .stack_slot });
                try value_ty_map.put(thir_vid, slot_ty);
            } else {
                const slot_ty = self.typeToBir(val_def.ty);
                try value_ty_map.put(thir_vid, slot_ty);
            }
        }

        var builder = Builder{
            .alloc = self.allocator,
            .mod = &self.module,
            .fid = func_id,
            .blk = block_map.get(body.entry) orelse 0,
            .lowerer = self,
            .body = &body,
            .block_map = &block_map,
            .param_map = &param_map,
            .value_map = &value_map,
            .value_ty_map = &value_ty_map,
            .ret_type = ret_ty,
            .store_log = std.ArrayList(Builder.StoreEntry).init(self.allocator),
        };
        defer builder.store_log.deinit();

        for (body.blocks, 0..) |*blk, i| {
            const bir_blk_id = block_map.get(ThirBlockId.new(@intCast(i))) orelse continue;
            builder.blk = bir_blk_id;

            for (blk.stmts) |stmt| {
                try builder.lowerStmt(stmt);
                if (builder.terminated()) break;
            }

            if (!builder.terminated()) {
                try builder.lowerTerminator(blk.terminator);
            }
        }

        try self.insertPhisAtMergeBlocks(&builder, func_id);
    }

    fn insertPhisAtMergeBlocks(self: *ThirToBir, builder: *Builder, func_id: bir.FunctionId) !void {
        var pred_map = std.AutoHashMap(BIRBlockId, std.ArrayList(BIRBlockId)).init(self.allocator);
        defer {
            var vit = pred_map.valueIterator();
            while (vit.next()) |list| list.deinit();
            pred_map.deinit();
        }

        {
            const func = self.module.getFunction(func_id);
            for (func.blocks.items, 0..) |blk, i| {
                if (blk.instrs.items.len == 0) continue;
                const blk_id: BIRBlockId = @intCast(i);
                const last = blk.instrs.items[blk.instrs.items.len - 1];
                switch (last.op) {
                    .br => {
                        if (last.data == .block_target) {
                            const target = last.data.block_target;
                            const gop = try pred_map.getOrPut(target);
                            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(BIRBlockId).init(self.allocator);
                            try gop.value_ptr.append(blk_id);
                        }
                    },
                    .cond_br => {
                        if (last.data == .cond_branch) {
                            const cb = last.data.cond_branch;
                            for ([_]BIRBlockId{ cb.then_block, cb.else_block }) |target| {
                                const gop = try pred_map.getOrPut(target);
                                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(BIRBlockId).init(self.allocator);
                                try gop.value_ptr.append(blk_id);
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        const blocks_list = self.module.getFunctionMut(func_id).blocks;
        for (blocks_list.items, 0..) |_, blk_idx| {
            const blk_id: BIRBlockId = @intCast(blk_idx);
            const preds = pred_map.get(blk_id) orelse continue;
            if (preds.items.len <= 1) continue;

            var slot_to_entries = std.AutoHashMap(BIRValueId, std.ArrayList(Builder.StoreEntry)).init(self.allocator);
            defer {
                var sit = slot_to_entries.valueIterator();
                while (sit.next()) |list| list.deinit();
                slot_to_entries.deinit();
            }

            for (builder.store_log.items) |entry| {
                for (preds.items) |pred| {
                    if (entry.block == pred) {
                        const gop = try slot_to_entries.getOrPut(entry.slot);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Builder.StoreEntry).init(self.allocator);
                        try gop.value_ptr.append(entry);
                        break;
                    }
                }
            }

            var slot_iter = slot_to_entries.iterator();
            while (slot_iter.next()) |kv| {
                if (kv.value_ptr.items.len < preds.items.len) continue;

                const slot = kv.key_ptr.*;
                const entries = kv.value_ptr.items;
                const ty = entries[0].ty;

                const incoming = try self.allocator.alloc(PhiIncoming, entries.len);
                for (entries, 0..) |entry, i| {
                    incoming[i] = .{ .block = entry.block, .value = entry.stored_value };
                }

                const phi_val = try self.module.addPhi(func_id, blk_id, ty, incoming);

                var vm_iter = builder.value_map.iterator();
                while (vm_iter.next()) |vm_kv| {
                    if (vm_kv.value_ptr.value == slot and vm_kv.value_ptr.kind == .stack_slot) {
                        vm_kv.value_ptr.* = .{ .value = phi_val, .kind = .ssa };
                        break;
                    }
                }
            }
        }
    }
};

fn makeInst(allocator: std.mem.Allocator, op: Op, ty: BIRTypeId, ops: []const BIRValueId, data: Inst.Data) !Inst {
    var owned_ops: []BIRValueId = &.{};
    if (ops.len > 0) {
        owned_ops = try allocator.dupe(BIRValueId, ops);
    }
    return .{ .op = op, .ty = ty, .result = BIR_NO_VALUE, .operands = owned_ops, .data = data };
}

const Builder = struct {
    alloc: std.mem.Allocator,
    mod: *bir.Module,
    fid: bir.FunctionId,
    blk: BIRBlockId,
    lowerer: *ThirToBir,
    body: *const ThirFunction.Body,
    block_map: *std.AutoHashMap(ThirBlockId, BIRBlockId),
    param_map: *std.AutoHashMap(DefId, ValueBinding),
    value_map: *std.AutoHashMap(ThirValueId, ValueBinding),
    value_ty_map: *std.AutoHashMap(ThirValueId, BIRTypeId),
    ret_type: BIRTypeId,

    store_log: std.ArrayList(StoreEntry),

    pub const ValueBinding = struct {
        value: BIRValueId,
        kind: Kind,

        pub const Kind = enum {
            ssa,
            address,
            stack_slot,
        };
    };

    pub const StoreEntry = struct {
        block: BIRBlockId,
        slot: BIRValueId,
        stored_value: BIRValueId,
        ty: BIRTypeId,
    };

    fn isTerminator(op: Op) bool {
        return switch (op) {
            .ret, .br, .cond_br, .unreachable_op => true,
            else => false,
        };
    }

    fn terminated(self: *Builder) bool {
        const bl = self.mod.getFunctionMut(self.fid).getBlock(self.blk);
        if (bl.instrs.items.len == 0) return false;
        return isTerminator(bl.instrs.items[bl.instrs.items.len - 1].op);
    }

    fn blockTerminated(self: *Builder, bir_blk: BIRBlockId) bool {
        const bl = self.mod.getFunctionMut(self.fid).getBlock(bir_blk);
        if (bl.instrs.items.len == 0) return false;
        return isTerminator(bl.instrs.items[bl.instrs.items.len - 1].op);
    }

    fn emitOp(self: *Builder, op: Op, ty: BIRTypeId, ops: []const BIRValueId, data: Inst.Data) !BIRValueId {
        return self.mod.addInst(self.fid, self.blk, try makeInst(self.alloc, op, ty, ops, data));
    }

    fn emitPhi(self: *Builder, ty: BIRTypeId, incoming: []const PhiIncoming) !BIRValueId {
        const owned = try self.alloc.dupe(PhiIncoming, incoming);
        const val = try self.mod.addPhi(self.fid, self.blk, ty, owned);
        return val;
    }

    fn emitAlloca(self: *Builder, func_id: bir.FunctionId, ty: BIRTypeId) !BIRValueId {
        return self.mod.addInst(func_id, self.blk, try makeInst(self.alloc, .alloca, ty, &.{}, .{ .none = {} }));
    }

    fn emitRet(self: *Builder, val: BIRValueId, ty: BIRTypeId) !void {
        if (val != BIR_NO_VALUE) {
            _ = try self.emitOp(.ret, ty, &.{val}, .{ .none = {} });
        } else {
            try self.retVoid();
        }
    }

    fn retVoid(self: *Builder) !void {
        const void_ty = self.mod.types.voidType() catch 0;
        _ = try self.emitOp(.ret, void_ty, &.{}, .{ .none = {} });
    }

    fn emitBr(self: *Builder, target: ThirBlockId) !void {
        const bir_target = self.block_map.get(target) orelse return;
        const void_ty = self.mod.types.voidType() catch 0;
        _ = try self.emitOp(.br, void_ty, &.{}, .{ .block_target = bir_target });
    }

    fn emitBrBir(self: *Builder, target: BIRBlockId) !void {
        const void_ty = self.mod.types.voidType() catch 0;
        _ = try self.emitOp(.br, void_ty, &.{}, .{ .block_target = target });
    }

    fn emitCondBr(self: *Builder, cond: BIRValueId, then_bir: BIRBlockId, else_bir: BIRBlockId) !void {
        const void_ty = self.mod.types.voidType() catch 0;
        _ = try self.emitOp(.cond_br, void_ty, &.{cond}, .{ .cond_branch = .{ .cond = cond, .then_block = then_bir, .else_block = else_bir } });
    }

    fn lookup(self: *Builder, vid: ThirValueId) ValueBinding {
        return self.value_map.get(vid) orelse .{ .value = BIR_NO_VALUE, .kind = .ssa };
    }

    fn lookupDef(self: *Builder, did: DefId) ValueBinding {
        return self.param_map.get(did) orelse .{ .value = BIR_NO_VALUE, .kind = .ssa };
    }

    fn storeSlot(self: *Builder, slot: BIRValueId, val: BIRValueId, ty: BIRTypeId) !void {
        _ = try self.emitOp(.store, ty, &.{ slot, val }, .{ .none = {} });
        try self.store_log.append(.{
            .block = self.blk,
            .slot = slot,
            .stored_value = val,
            .ty = ty,
        });
    }

    fn loadFromSlot(self: *Builder, slot: BIRValueId, ty: BIRTypeId) !BIRValueId {
        return self.emitOp(.load, ty, &.{slot}, .{ .none = {} });
    }

    fn lowerStmt(self: *Builder, stmt: ThirStmt) LowerError!void {
        if (self.terminated()) return;

        switch (stmt.kind) {
            .let => |let_stmt| {
                const binding = self.lookup(let_stmt.place);
                if (binding.value == BIR_NO_VALUE) return;
                const slot_ty = self.value_ty_map.get(let_stmt.place) orelse (self.mod.types.voidType() catch 0);
                if (let_stmt.init.isValid()) {
                    const init_val = try self.lowerValueExpr(let_stmt.init);
                    if (init_val != BIR_NO_VALUE) {
                        try self.storeSlot(binding.value, init_val, slot_ty);
                    }
                }
            },
            .assignment => |assign_stmt| {
                const binding = self.lookup(assign_stmt.place);
                if (binding.value == BIR_NO_VALUE) return;
                const slot_ty = self.value_ty_map.get(assign_stmt.place) orelse (self.mod.types.voidType() catch 0);
                const val = try self.lowerValueExpr(assign_stmt.value);
                if (val != BIR_NO_VALUE) {
                    try self.storeSlot(binding.value, val, slot_ty);
                }
            },
            .expr_stmt => |es| {
                _ = try self.lowerValueExpr(es.expr);
            },
            .if_stmt => |ifs| {
                const cond_val = try self.lowerValueExpr(ifs.cond);
                const then_bir = self.block_map.get(ifs.then_block) orelse return;
                if (ifs.else_block) |else_blk| {
                    const else_bir = self.block_map.get(else_blk) orelse return;
                    try self.emitCondBr(cond_val, then_bir, else_bir);
                } else {
                    const merge = try self.newBlock("if_merge");
                    try self.emitCondBr(cond_val, then_bir, merge);
                }
            },
            .while_stmt => |ws| {
                try self.emitBr(ws.cond_block);
            },
            .return_stmt => |rs| {
                if (rs.value) |val| {
                    const ret_val = try self.lowerValueExpr(val);
                    try self.emitRet(ret_val, self.ret_type);
                } else {
                    try self.retVoid();
                }
            },
            .break_stmt => |bs| {
                try self.emitBr(bs.target_loop);
            },
            .continue_stmt => |cs| {
                try self.emitBr(cs.target_loop);
            },
            .block => |blk_stmt| {
                try self.emitBr(blk_stmt.block);
            },
        }
    }

    fn lowerTerminator(self: *Builder, term: BasicBlock.Terminator) LowerError!void {
        switch (term) {
            .br => |target| {
                try self.emitBr(target);
            },
            .cond_br => |cb| {
                const cond_val = try self.lowerValueExpr(cb.cond);
                const then_bir = self.block_map.get(cb.then) orelse return;
                const else_bir = self.block_map.get(cb.else_) orelse return;
                try self.emitCondBr(cond_val, then_bir, else_bir);
            },
            .switch_br => |sb| {
                _ = sb;
                try self.retVoid();
            },
            .return_ret => |rr| {
                if (rr.value) |val| {
                    const ret_val = try self.lowerValueExpr(val);
                    try self.emitRet(ret_val, self.ret_type);
                } else {
                    try self.retVoid();
                }
            },
            .unreachable_term => {
                const void_ty = self.mod.types.voidType() catch 0;
                _ = try self.emitOp(.unreachable_op, void_ty, &.{}, .{ .none = {} });
            },
            .diverge => {
                const void_ty = self.mod.types.voidType() catch 0;
                _ = try self.emitOp(.unreachable_op, void_ty, &.{}, .{ .none = {} });
            },
        }
    }

    fn lowerValueExpr(self: *Builder, vid: ThirValueId) LowerError!BIRValueId {
        if (!vid.isValid() or vid.index >= self.body.values.len) return BIR_NO_VALUE;
        const value_def = self.body.values[vid.index];

        if (!value_def.expr.isValid() or value_def.expr.index >= self.body.exprs.len) {
            const binding = self.lookup(vid);
            if (binding.value == BIR_NO_VALUE) return BIR_NO_VALUE;
            if (binding.kind == .ssa) return binding.value;
            const slot_ty = self.value_ty_map.get(vid) orelse (self.mod.types.voidType() catch 0);
            return self.loadFromSlot(binding.value, slot_ty);
        }

        const expr = self.body.exprs[value_def.expr.index];
        switch (expr.kind) {
            .literal => |lit| return self.lowerLiteral(lit, expr.ty),
            .binary => |bin| return self.lowerBinary(bin, expr.ty),
            .unary => |un| return self.lowerUnary(un, expr.ty),
            .call => |call| return self.lowerCall(call, expr.ty),
            .cast => |cast| return self.lowerCast(cast, expr.ty),
            .load => |ld| return self.lowerLoad(ld, expr.ty),
            .addr_of => |ao| return self.lowerAddrOf(ao, expr.ty),
            .deref => |dr| return self.lowerDeref(dr, expr.ty),
            .field_addr => |fa| return self.lowerFieldAddr(fa, expr.ty),
            .index_addr => |ia| return self.lowerIndexAddr(ia, expr.ty),
            .unit => return BIR_NO_VALUE,
            .none => {},
            else => {},
        }

        const binding = self.lookup(vid);
        if (binding.value == BIR_NO_VALUE) return BIR_NO_VALUE;
        if (binding.kind == .ssa) return binding.value;
        const slot_ty = self.value_ty_map.get(vid) orelse (self.mod.types.voidType() catch 0);
        return self.loadFromSlot(binding.value, slot_ty);
    }

    fn lowerLiteral(self: *Builder, lit: Literal, ty: type_sys.TypeId) LowerError!BIRValueId {
        const bir_ty = self.lowerer.typeToBir(ty);
        return switch (lit) {
            .int => |v| self.emitOp(.@"const", bir_ty, &.{}, .{ .const_data = .{ .int = v } }),
            .float => |v| self.emitOp(.@"const", bir_ty, &.{}, .{ .const_data = .{ .float = v } }),
            .bool_val => |v| self.emitOp(.@"const", bir_ty, &.{}, .{ .const_data = .{ .bool = v } }),
            .string => self.emitOp(.@"const", bir_ty, &.{}, .{ .const_data = .{ .int = 0 } }),
            .unit => BIR_NO_VALUE,
        };
    }

    fn lowerBinary(self: *Builder, bin: ThirExpr.BinaryExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const lhs = try self.lowerValueExpr(bin.lhs);
        const rhs = try self.lowerValueExpr(bin.rhs);
        if (lhs == BIR_NO_VALUE or rhs == BIR_NO_VALUE) return BIR_NO_VALUE;

        const bir_ty = self.lowerer.typeToBir(ty);
        const bir_op = switch (bin.op) {
            .add => Op.add,
            .sub => Op.sub,
            .mul => Op.mul,
            .div => Op.div,
            .mod => Op.mod,
            .eq => Op.eq,
            .ne => Op.ne,
            .lt => Op.lt,
            .le => Op.le,
            .gt => Op.gt,
            .ge => Op.ge,
            .and_ => Op.and_op,
            .or_ => Op.or_op,
            .bitwise_and => Op.and_op,
            .bitwise_or => Op.or_op,
            .bitwise_xor => Op.xor_op,
            .shl => Op.shl,
            .shr => Op.shr,
        };
        return self.emitOp(bir_op, bir_ty, &.{ lhs, rhs }, .{ .none = {} });
    }

    fn lowerUnary(self: *Builder, un: ThirExpr.UnaryExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const operand = try self.lowerValueExpr(un.operand);
        if (operand == BIR_NO_VALUE) return BIR_NO_VALUE;

        const bir_ty = self.lowerer.typeToBir(ty);
        const bir_op = switch (un.op) {
            .negate => Op.neg,
            .not => Op.not,
            .bitwise_not => Op.not,
        };
        return self.emitOp(bir_op, bir_ty, &.{operand}, .{ .none = {} });
    }

    fn lowerCall(self: *Builder, call: ThirExpr.CallExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        var args = std.ArrayList(BIRValueId).init(self.alloc);
        defer args.deinit();

        for (call.args) |arg| {
            const val = try self.lowerValueExpr(arg);
            if (val != BIR_NO_VALUE) {
                try args.append(val);
            }
        }

        const void_ty = self.mod.types.voidType() catch 0;
        const result_ty = if (ty.index != 0) self.lowerer.typeToBir(ty) else void_ty;

        const callee_name = switch (call.func) {
            .function => |def_id| try std.fmt.allocPrint(self.alloc, "fn_{d}", .{def_id.index}),
            .value => try std.fmt.allocPrint(self.alloc, "closure_{d}", .{call.func.value.index}),
        };
        defer self.alloc.free(callee_name);

        const owned_args = try self.alloc.dupe(BIRValueId, args.items);
        return self.emitOp(.call, result_ty, &.{}, .{ .named_call = .{ .name = callee_name, .args = owned_args } });
    }

    fn lowerCast(self: *Builder, cast: ThirExpr.CastExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const operand = try self.lowerValueExpr(cast.operand);
        if (operand == BIR_NO_VALUE) return BIR_NO_VALUE;

        const bir_ty = self.lowerer.typeToBir(ty);
        const from_bir_ty = self.lowerer.typeToBir(cast.from_ty);

        switch (cast.kind) {
            .int_extend_signed => return self.emitOp(.sext, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .signext, .from = from_bir_ty, .to = bir_ty } }),
            .int_extend_unsigned => return self.emitOp(.zext, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .zeroext, .from = from_bir_ty, .to = bir_ty } }),
            .int_truncate => return self.emitOp(.trunc, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .trunc, .from = from_bir_ty, .to = bir_ty } }),
            .int_to_float => return self.emitOp(.sitofp, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .i2f, .from = from_bir_ty, .to = bir_ty } }),
            .uint_to_float => return self.emitOp(.sitofp, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .i2f, .from = from_bir_ty, .to = bir_ty } }),
            .float_to_int => return self.emitOp(.fptosi, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .f2i, .from = from_bir_ty, .to = bir_ty } }),
            .float_to_uint => return self.emitOp(.fptosi, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .f2i, .from = from_bir_ty, .to = bir_ty } }),
            .float_extend => return self.emitOp(.fpext, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .f2f, .from = from_bir_ty, .to = bir_ty } }),
            .float_truncate => return self.emitOp(.fptrunc, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .f2f, .from = from_bir_ty, .to = bir_ty } }),
            .bool_to_int => return self.emitOp(.zext, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .zeroext, .from = from_bir_ty, .to = bir_ty } }),
            .int_to_bool => return self.emitOp(.trunc, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .trunc, .from = from_bir_ty, .to = bir_ty } }),
            .bitcast => return self.emitOp(.bitcast, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .bitcast, .from = from_bir_ty, .to = bir_ty } }),
            .pointer_cast => return self.emitOp(.bitcast, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .bitcast, .from = from_bir_ty, .to = bir_ty } }),
            .pointer_to_int => return self.emitOp(.ptr_to_int, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .ptr2int, .from = from_bir_ty, .to = bir_ty } }),
            .int_to_pointer => return self.emitOp(.int_to_ptr, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .int2ptr, .from = from_bir_ty, .to = bir_ty } }),
            .unsize => return self.emitOp(.bitcast, bir_ty, &.{operand}, .{ .cast_info = .{ .kind = .bitcast, .from = from_bir_ty, .to = bir_ty } }),
        }
    }

    fn lowerLoad(self: *Builder, ld: ThirExpr.LoadExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const ptr = try self.lowerPlace(ld.place);
        if (ptr == BIR_NO_VALUE) return BIR_NO_VALUE;
        const bir_ty = self.lowerer.typeToBir(ty);
        return self.emitOp(.load, bir_ty, &.{ptr}, .{ .none = {} });
    }

    fn lowerPlace(self: *Builder, place: ThirPlace) LowerError!BIRValueId {
        if (!place.local.isValid()) return BIR_NO_VALUE;

        const binding = self.lookup(place.local);
        var ptr = binding.value;
        if (ptr == BIR_NO_VALUE) return BIR_NO_VALUE;
        const current_ty = self.value_ty_map.get(place.local) orelse (self.mod.types.voidType() catch 0);

        for (place.projections) |proj| {
            switch (proj) {
                .field => |field_idx| {
                    const idx_ty = try self.mod.types.scalarType(.i32);
                    const idx = try self.emitOp(.@"const", idx_ty, &.{}, .{ .const_data = .{ .int = @intCast(field_idx) } });
                    ptr = try self.emitOp(.getelementptr, current_ty, &.{ ptr, idx }, .{ .none = {} });
                },
                .index => |index_vid| {
                    const idx = try self.lowerValueExpr(index_vid);
                    if (idx == BIR_NO_VALUE) return BIR_NO_VALUE;
                    ptr = try self.emitOp(.getelementptr, current_ty, &.{ ptr, idx }, .{ .none = {} });
                },
                .deref => {
                    // ptr already holds the address — no-op for Place semantics
                },
                .downcast => |_| {},
            }
        }

        return ptr;
    }

    fn lowerAddrOf(self: *Builder, ao: ThirExpr.AddrOfExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const operand = try self.lowerValueExpr(ao.operand);
        if (operand == BIR_NO_VALUE) return BIR_NO_VALUE;
        const bir_ty = self.lowerer.typeToBir(ty);
        return self.emitOp(.getelementptr, bir_ty, &.{operand}, .{ .none = {} });
    }

    fn lowerDeref(self: *Builder, dr: ThirExpr.DerefExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const operand = try self.lowerValueExpr(dr.operand);
        if (operand == BIR_NO_VALUE) return BIR_NO_VALUE;
        const bir_ty = self.lowerer.typeToBir(ty);
        return self.emitOp(.load, bir_ty, &.{operand}, .{ .none = {} });
    }

    fn lowerFieldAddr(self: *Builder, fa: ThirExpr.FieldAddrExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const object = try self.lowerValueExpr(fa.object);
        if (object == BIR_NO_VALUE) return BIR_NO_VALUE;
        const bir_ty = self.lowerer.typeToBir(ty);
        const idx_val = try self.emitOp(.@"const", (self.lowerer.module.types.scalarType(.i32) catch 0), &.{}, .{ .const_data = .{ .int = @intCast(fa.field_index) } });
        return self.emitOp(.getelementptr, bir_ty, &.{ object, idx_val }, .{ .none = {} });
    }

    fn lowerIndexAddr(self: *Builder, ia: ThirExpr.IndexAddrExpr, ty: type_sys.TypeId) LowerError!BIRValueId {
        const object = try self.lowerValueExpr(ia.object);
        const index = try self.lowerValueExpr(ia.index);
        if (object == BIR_NO_VALUE or index == BIR_NO_VALUE) return BIR_NO_VALUE;
        const bir_ty = self.lowerer.typeToBir(ty);
        return self.emitOp(.getelementptr, bir_ty, &.{ object, index }, .{ .none = {} });
    }

    fn newBlock(self: *Builder, prefix: []const u8) !BIRBlockId {
        const label = try std.fmt.allocPrint(self.alloc, "{s}_{d}", .{ prefix, @as(u32, @intCast(self.mod.getFunctionMut(self.fid).blocks.items.len)) });
        defer self.alloc.free(label);
        return try self.mod.addBlock(self.fid, label);
    }
};
