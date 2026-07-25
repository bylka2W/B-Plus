const std = @import("std");
const hir_mod = @import("../frontend/hir/arena.zig");
const HirArena = hir_mod.HirArena;
const HirExpr = hir_mod.HirExpr;
const HirStmt = hir_mod.HirStmt;
const HirItem = hir_mod.HirItem;
const type_sys = @import("../frontend/type_system/type_system.zig");
const TypeEngine = type_sys.TypeEngine;
const TypeData = type_sys.TypeData;
const BuiltinKind = type_sys.BuiltinKind;
const bir = @import("bir/bir.zig");
const bir_types = bir.types;
const BIRTypeId = bir_types.TypeId;
const ScalarKind = bir_types.ScalarKind;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const FunctionId = bir.ValueId;
const Inst = bir.Inst;
const Op = bir.Op;
const NO_VALUE = bir.NO_VALUE;
const ExprId = hir_mod.ExprId;
const StmtId = hir_mod.StmtId;
const ItemId = hir_mod.ItemId;
const BodyId = hir_mod.BodyId;
const ids = @import("../frontend/foundation/ids/ids.zig");
const DefId = ids.DefId;
const SymbolId = ids.SymbolId;

pub const LowerError = error{ TypeError, UnresolvedType, OutOfMemory };

pub const HirToBir = struct {
    allocator: std.mem.Allocator,
    hir: *HirArena,
    engine: *TypeEngine,
    module: bir.Module,
    block_label_counter: u32,

    pub fn init(allocator: std.mem.Allocator, hir: *HirArena, engine: *TypeEngine) HirToBir {
        return .{
            .allocator = allocator,
            .hir = hir,
            .engine = engine,
            .module = bir.Module.init(allocator),
            .block_label_counter = 0,
        };
    }

    pub fn deinit(self: *HirToBir) void {
        self.module.deinit();
    }

    pub fn lower(self: *HirToBir) LowerError!bir.Module {
        try self.ensureBuiltinTypes();
        var i: u32 = 0;
        while (i < self.hir.itemCount()) : (i += 1) {
            const item_id = ItemId.new(i);
            const item = self.hir.getItem(item_id) orelse continue;
            try self.lowerItem(item);
        }
        const m = self.module;
        self.module = bir.Module.init(self.allocator);
        return m;
    }

    fn nextBlockLabel(self: *HirToBir, prefix: []const u8) ![]const u8 {
        self.block_label_counter += 1;
        return std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, self.block_label_counter });
    }

    fn ensureBuiltinTypes(self: *HirToBir) !void {
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

    fn builtinToBir(self: *HirToBir, kind: BuiltinKind) BIRTypeId {
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

    fn typeToBir(self: *HirToBir, ty: type_sys.TypeId) BIRTypeId {
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

    fn lowerItem(self: *HirToBir, item: HirItem) LowerError!void {
        switch (item.kind) {
            .fn_decl => |f| try self.lowerFnDecl(f),
            .const_item => {}, // TODO
            .struct_item => {}, // TODO
            .enum_item => {}, // TODO
            .trait_item => {}, // TODO
            .impl_item => {}, // TODO
            .type_alias => {}, // TODO
            .extern_fn => {}, // TODO
            .state_item => {}, // TODO
            .kernel_item => {}, // TODO
            .missing => {},
        }
    }

    fn lowerFnDecl(self: *HirToBir, f: HirItem.HirItemKind.FnItem) LowerError!void {
        const ret_ty = self.typeToBir(f.return_type);
        const func_name = try std.fmt.allocPrint(self.allocator, "fn_{d}", .{f.def_id.index});
        defer self.allocator.free(func_name);
        const func_id = try self.module.addFunction(
            func_name,
            ret_ty,
            .internal,
        );

        {
            const fn_mut = self.module.getFunctionMut(func_id);
            const owned_params = try self.allocator.alloc(bir.FuncParam, f.params.len);
            const owned_values = try self.allocator.alloc(ValueId, f.params.len);
            for (f.params, 0..) |param, i| {
                const param_ty = self.typeToBir(param.ty);
                owned_params[i] = .{
                    .name = try std.fmt.allocPrint(self.allocator, "param_{d}", .{param.name.index}),
                    .ty = param_ty,
                };
                owned_values[i] = try fn_mut.createValue();
            }
            fn_mut.params = owned_params;
            fn_mut.param_values = owned_values;
        }

        const entry_id = try self.module.addBlock(func_id, "entry");
        var b = Builder{
            .alloc = self.allocator,
            .mod = &self.module,
            .fid = func_id,
            .blk = entry_id,
            .hir_to_bir = self,
            .def_values = std.AutoHashMap(DefId, ValueId).init(self.allocator),
            .def_types = std.AutoHashMap(DefId, BIRTypeId).init(self.allocator),
            .ret_type = ret_ty,
        };
        defer b.def_values.deinit();
        defer b.def_types.deinit();

        for (f.params, 0..) |param, i| {
            try b.def_values.put(param.def_id, self.module.getFunction(func_id).param_values[i]);
            try b.def_types.put(param.def_id, self.typeToBir(param.ty));
        }

        if (f.body.isValid()) {
            if (self.hir.getBody(f.body)) |body| {
                try b.lowerBody(body);
            }
        }

        if (!b.terminated()) {
            try b.retVoid();
        }
    }
};

fn makeInst(allocator: std.mem.Allocator, op: Op, ty: BIRTypeId, ops: []const ValueId, data: Inst.Data) !Inst {
    var owned_ops: []ValueId = &.{};
    if (ops.len > 0) {
        owned_ops = try allocator.dupe(ValueId, ops);
    }
    return .{ .op = op, .ty = ty, .result = NO_VALUE, .operands = owned_ops, .data = data };
}

const VarInfo = struct {
    value: ValueId,
    type_id: BIRTypeId,
};

const Builder = struct {
    alloc: std.mem.Allocator,
    mod: *bir.Module,
    fid: bir.FunctionId,
    blk: BlockId,
    hir_to_bir: *HirToBir,
    def_values: std.AutoHashMap(DefId, ValueId),
    def_types: std.AutoHashMap(DefId, BIRTypeId),
    ret_type: BIRTypeId,

    fn terminated(self: *Builder) bool {
        const bl = self.mod.getFunctionMut(self.fid).getBlock(self.blk);
        if (bl.instrs.items.len == 0) return false;
        const last = bl.instrs.items[bl.instrs.items.len - 1];
        return last.op == .ret or last.op == .br or last.op == .cond_br;
    }

    fn emitOp(self: *Builder, op: Op, ty: BIRTypeId, ops: []const ValueId, data: Inst.Data) !ValueId {
        return self.mod.addInst(self.fid, self.blk, try makeInst(self.alloc, op, ty, ops, data));
    }

    fn emitRet(self: *Builder, val: ValueId, ty: BIRTypeId) !void {
        if (val != NO_VALUE) {
            _ = try self.emitOp(.ret, ty, &.{val}, .{ .none = {} });
        } else {
            try self.retVoid();
        }
    }

    fn retVoid(self: *Builder) !void {
        const void_ty = self.mod.types.voidType() catch 0;
        _ = try self.emitOp(.ret, void_ty, &.{}, .{ .none = {} });
    }

    fn emitBr(self: *Builder, target: BlockId) !void {
        const void_ty = self.mod.types.voidType() catch 0;
        _ = try self.emitOp(.br, void_ty, &.{}, .{ .block_target = target });
    }

    fn emitCondBr(self: *Builder, cond: ValueId, then_b: BlockId, else_b: BlockId) !void {
        const void_ty = self.mod.types.voidType() catch 0;
        _ = try self.emitOp(.cond_br, void_ty, &.{cond}, .{ .cond_branch = .{ .cond = cond, .then_block = then_b, .else_block = else_b } });
    }

    fn emitStore(self: *Builder, ty: BIRTypeId, slot: ValueId, val: ValueId) !void {
        _ = try self.emitOp(.store, ty, &.{ slot, val }, .{ .none = {} });
    }

    fn emitLoad(self: *Builder, slot: ValueId, ty: BIRTypeId) !ValueId {
        return self.emitOp(.load, ty, &.{slot}, .{ .none = {} });
    }

    fn emitAlloca(self: *Builder, ty: BIRTypeId) !ValueId {
        return self.emitOp(.alloca, ty, &.{}, .{ .none = {} });
    }

    fn emitConstInt(self: *Builder, v: i64) !ValueId {
        const i64_ty = self.hir_to_bir.builtinToBir(.i64_type);
        return self.emitOp(.@"const", i64_ty, &.{}, .{ .const_data = .{ .int = v } });
    }

    fn emitConstBool(self: *Builder, v: bool) !ValueId {
        const i1_ty = self.hir_to_bir.builtinToBir(.bool_type);
        return self.emitOp(.@"const", i1_ty, &.{}, .{ .const_data = .{ .bool = v } });
    }

    fn emitConstFloat(self: *Builder, v: f64) !ValueId {
        const f64_ty = self.hir_to_bir.builtinToBir(.f64_type);
        return self.emitOp(.@"const", f64_ty, &.{}, .{ .const_data = .{ .float = v } });
    }

    fn newBlock(self: *Builder, prefix: []const u8) !BlockId {
        const label = try self.hir_to_bir.nextBlockLabel(prefix);
        defer self.alloc.free(label);
        return try self.mod.addBlock(self.fid, label);
    }

    fn lowerBody(self: *Builder, body: hir_mod.HirBody) LowerError!void {
        _ = try self.lowerExpr(body.entry);
    }

    fn lowerStmt(self: *Builder, stmt_id: StmtId) LowerError!void {
        if (!stmt_id.isValid()) return;
        const stmt = self.hir_to_bir.hir.getStmt(stmt_id) orelse return;
        if (self.terminated()) return;

        switch (stmt.kind) {
            .local_decl => |ld| try self.lowerLocalDecl(ld),
            .expr => |es| {
                _ = try self.lowerExpr(es.expr);
            },
            .block => |bs| {
                for (bs.stmts) |sid| {
                    try self.lowerStmt(sid);
                }
            },
            .if_stmt => |ifs| try self.lowerIfStmt(ifs),
            .while_stmt => |ws| try self.lowerWhileStmt(ws),
            .for_stmt => {}, // TODO
            .loop_stmt => |ls| try self.lowerLoopStmt(ls),
            .return_stmt => |rs| try self.lowerReturnStmt(rs),
            .break_stmt => |bs| try self.lowerBreakStmt(bs),
            .continue_stmt => {},
            .defer_stmt => {}, // TODO
            .errdefer_stmt => {}, // TODO
            .missing => {},
        }
    }

    fn lowerLocalDecl(self: *Builder, ld: anytype) LowerError!void {
        var init_ty = self.hir_to_bir.typeToBir(self.hir_to_bir.engine.freshVar());
        if (ld.init) |init_expr| {
            const val = try self.lowerExpr(init_expr);
            if (val != NO_VALUE) {
                const expr = self.hir_to_bir.hir.getExpr(init_expr);
                if (expr) |e| {
                    init_ty = self.hir_to_bir.typeToBir(e.ty);
                }
            }
        }
        if (ld.type_annotation) |ann_ty| {
            init_ty = self.hir_to_bir.typeToBir(ann_ty);
        }
        const slot = try self.emitAlloca(init_ty);
        try self.checkPatternDef(ld.pattern, slot, init_ty);
    }

    fn checkPatternDef(self: *Builder, pat_id: anytype, slot: ValueId, ty: BIRTypeId) LowerError!void {
        const pat = self.hir_to_bir.hir.getPattern(pat_id) orelse return;
        switch (pat.kind) {
            .binding => |b| {
                try self.def_values.put(b.def, slot);
                try self.def_types.put(b.def, ty);
            },
            else => {},
        }
    }

    fn lowerIfStmt(self: *Builder, ifs: HirStmt.HirStmtKind.IfStmt) LowerError!void {
        const cond_val = try self.lowerExpr(ifs.condition);
        const then_block = try self.newBlock("if_then");
        const else_block = try self.newBlock("if_else");
        const merge_block = try self.newBlock("if_merge");

        try self.emitCondBr(cond_val, then_block, else_block);

        self.blk = then_block;
        try self.lowerStmt(ifs.then_branch);
        if (!self.terminated()) {
            try self.emitBr(merge_block);
        }

        self.blk = else_block;
        if (ifs.else_branch) |eb| {
            try self.lowerStmt(eb);
        }
        if (!self.terminated()) {
            try self.emitBr(merge_block);
        }

        self.blk = merge_block;
    }

    fn lowerWhileStmt(self: *Builder, ws: HirStmt.HirStmtKind.WhileStmt) LowerError!void {
        const header_block = try self.newBlock("while_header");
        const body_block = try self.newBlock("while_body");
        const exit_block = try self.newBlock("while_exit");

        try self.emitBr(header_block);

        self.blk = header_block;
        const cond_val = try self.lowerExpr(ws.condition);
        try self.emitCondBr(cond_val, body_block, exit_block);

        self.blk = body_block;
        try self.lowerStmt(ws.body);
        if (!self.terminated()) {
            try self.emitBr(header_block);
        }

        self.blk = exit_block;
    }

    fn lowerLoopStmt(self: *Builder, ls: HirStmt.HirStmtKind.LoopStmt) LowerError!void {
        const body_block = try self.newBlock("loop_body");
        const exit_block = try self.newBlock("loop_exit");

        try self.emitBr(body_block);
        self.blk = body_block;
        try self.lowerStmt(ls.body);
        if (!self.terminated()) {
            try self.emitBr(body_block);
        }

        self.blk = exit_block;
    }

    fn lowerReturnStmt(self: *Builder, rs: HirStmt.HirStmtKind.ReturnStmt) LowerError!void {
        if (rs.value) |val| {
            const ret_val = try self.lowerExpr(val);
            try self.emitRet(ret_val, self.ret_type);
        } else {
            try self.retVoid();
        }
    }

    fn lowerBreakStmt(self: *Builder, bs: HirStmt.HirStmtKind.BreakStmt) LowerError!void {
        _ = bs;
        const void_ty = self.hir_to_bir.builtinToBir(.void_type);
        _ = try self.emitOp(.ret, void_ty, &.{}, .{ .none = {} });
    }

    fn lowerExpr(self: *Builder, expr_id: ExprId) LowerError!ValueId {
        if (!expr_id.isValid()) return NO_VALUE;
        const expr = self.hir_to_bir.hir.getExpr(expr_id) orelse return NO_VALUE;

        return switch (expr.kind) {
            .literal => |lit| try self.lowerLiteral(lit, expr.ty),
            .path => |p| try self.lowerPath(p),
            .binary => |b| try self.lowerBinary(b),
            .unary => |u| try self.lowerUnary(u),
            .block => |blk| try self.lowerBlockExpr(blk),
            .if_expr => |i| try self.lowerIfExpr(i, self.hir_to_bir.typeToBir(expr.ty)),
            .while_expr => |w| try self.lowerWhileExpr(w),
            .loop_expr => |l| try self.lowerLoopExpr(l),
            .return_expr => |r| try self.lowerReturnExpr(r),
            .assign => |a| try self.lowerAssign(a),
            .call => |c| try self.lowerCall(c),
            .missing, .continue_expr => NO_VALUE,
            else => NO_VALUE,
        };
    }

    fn lowerLiteral(self: *Builder, lit: HirExpr.HirExprKind.LiteralExpr, ty: type_sys.TypeId) LowerError!ValueId {
        return switch (lit.value) {
            .int => |v| {
                const bir_ty = self.hir_to_bir.typeToBir(ty);
                return self.emitOp(.@"const", bir_ty, &.{}, .{ .const_data = .{ .int = v } });
            },
            .float => |v| {
                const bir_ty = self.hir_to_bir.typeToBir(ty);
                return self.emitOp(.@"const", bir_ty, &.{}, .{ .const_data = .{ .float = v } });
            },
            .boolean => |v| {
                return self.emitConstBool(v);
            },
            .string => |s| {
                _ = s;
                return self.hir_to_bir.module.types.pointerType(0, .generic) catch NO_VALUE;
            },
        };
    }

    fn lowerPath(self: *Builder, p: HirExpr.HirExprKind.PathExpr) LowerError!ValueId {
        if (self.def_values.get(p.def)) |slot| {
            const ty = self.def_types.get(p.def) orelse (self.hir_to_bir.module.types.voidType() catch 0);
            return self.emitLoad(slot, ty);
        }
        return NO_VALUE;
    }

    fn lowerBinary(self: *Builder, b: HirExpr.HirExprKind.BinaryExpr) LowerError!ValueId {
        const left_val = try self.lowerExpr(b.left);
        const right_val = try self.lowerExpr(b.right);
        if (left_val == NO_VALUE or right_val == NO_VALUE) return NO_VALUE;

        const left_expr = self.hir_to_bir.hir.getExpr(b.left);
        const right_expr = self.hir_to_bir.hir.getExpr(b.right);
        const left_ty = if (left_expr) |e| self.hir_to_bir.typeToBir(e.ty) else (self.hir_to_bir.module.types.voidType() catch 0);
        _ = right_expr;

        const bir_op = switch (b.op) {
            .add => Op.add,
            .sub => Op.sub,
            .mul => Op.mul,
            .div => Op.div,
            .mod => Op.mod,
            .eq => Op.eq,
            .ne => Op.ne,
            .lt => Op.lt,
            .gt => Op.gt,
            .le => Op.le,
            .ge => Op.ge,
            .and_ => Op.and_op,
            .or_ => Op.or_op,
            .bitwise_and => Op.and_op,
            .bitwise_or => Op.or_op,
            .bitwise_xor => Op.xor_op,
            .shl => Op.shl,
            .shr => Op.shr,
        };

        const result_ty = left_ty;
        return self.emitOp(bir_op, result_ty, &.{ left_val, right_val }, .{ .none = {} });
    }

    fn lowerUnary(self: *Builder, u: HirExpr.HirExprKind.UnaryExpr) LowerError!ValueId {
        const operand_val = try self.lowerExpr(u.operand);
        if (operand_val == NO_VALUE) return NO_VALUE;

        const operand_expr = self.hir_to_bir.hir.getExpr(u.operand);
        const operand_ty = if (operand_expr) |e| self.hir_to_bir.typeToBir(e.ty) else (self.hir_to_bir.module.types.voidType() catch 0);

        const bir_op = switch (u.op) {
            .negate => Op.neg,
            .not => Op.not,
            .bitwise_not => Op.not,
            .borrow => Op.add,
            .address_of => Op.add,
            .dereference => Op.load,
        };

        if (u.op == .address_of or u.op == .borrow) {
            return self.emitOp(.getelementptr, operand_ty, &.{operand_val}, .{ .none = {} });
        }
        if (u.op == .dereference) {
            return self.emitOp(.load, operand_ty, &.{operand_val}, .{ .none = {} });
        }

        return self.emitOp(bir_op, operand_ty, &.{operand_val}, .{ .none = {} });
    }

    fn lowerBlockExpr(self: *Builder, b: HirExpr.HirExprKind.BlockExpr) LowerError!ValueId {
        for (b.stmts) |sid| {
            try self.lowerStmt(sid);
            if (self.terminated()) return NO_VALUE;
        }
        if (b.result.isValid()) {
            return self.lowerExpr(b.result);
        }
        return NO_VALUE;
    }

    fn lowerIfExpr(self: *Builder, i: HirExpr.HirExprKind.IfExpr, result_ty: BIRTypeId) LowerError!ValueId {
        const cond_val = try self.lowerExpr(i.condition);
        const then_block = try self.newBlock("if_then");
        const else_block = try self.newBlock("if_else");
        const merge_block = try self.newBlock("if_merge");

        const result_alloca = try self.emitAlloca(result_ty);

        try self.emitCondBr(cond_val, then_block, else_block);

        self.blk = then_block;
        const then_val = try self.lowerExpr(i.then_branch);
        if (then_val != NO_VALUE) {
            try self.emitStore(result_ty, result_alloca, then_val);
        }
        if (!self.terminated()) {
            try self.emitBr(merge_block);
        }

        self.blk = else_block;
        if (i.else_branch.isValid()) {
            const else_val = try self.lowerExpr(i.else_branch);
            if (else_val != NO_VALUE) {
                try self.emitStore(result_ty, result_alloca, else_val);
            }
        }
        if (!self.terminated()) {
            try self.emitBr(merge_block);
        }

        self.blk = merge_block;
        return self.emitLoad(result_alloca, result_ty);
    }

    fn lowerWhileExpr(self: *Builder, w: HirExpr.HirExprKind.WhileExpr) LowerError!ValueId {
        const header_block = try self.newBlock("while_header");
        const body_block = try self.newBlock("while_body");
        const exit_block = try self.newBlock("while_exit");

        try self.emitBr(header_block);
        self.blk = header_block;
        const cond_val = try self.lowerExpr(w.condition);
        try self.emitCondBr(cond_val, body_block, exit_block);

        self.blk = body_block;
        _ = try self.lowerExpr(w.body);
        if (!self.terminated()) {
            try self.emitBr(header_block);
        }

        self.blk = exit_block;
        return NO_VALUE;
    }

    fn lowerLoopExpr(self: *Builder, l: HirExpr.HirExprKind.LoopExpr) LowerError!ValueId {
        const body_block = try self.newBlock("loop_body");
        const exit_block = try self.newBlock("loop_exit");

        try self.emitBr(body_block);
        self.blk = body_block;
        _ = try self.lowerExpr(l.body);
        if (!self.terminated()) {
            try self.emitBr(body_block);
        }

        self.blk = exit_block;
        return NO_VALUE;
    }

    fn lowerReturnExpr(self: *Builder, r: HirExpr.HirExprKind.ReturnExpr) LowerError!ValueId {
        if (r.value.isValid()) {
            const val = try self.lowerExpr(r.value);
            try self.emitRet(val, self.ret_type);
        } else {
            try self.retVoid();
        }
        return NO_VALUE;
    }

    fn lowerAssign(self: *Builder, a: HirExpr.HirExprKind.AssignExpr) LowerError!ValueId {
        const target_expr = self.hir_to_bir.hir.getExpr(a.target);
        if (target_expr) |te| {
            switch (te.kind) {
                .path => |p| {
                    if (self.def_values.get(p.def)) |slot| {
                        const ty = self.def_types.get(p.def) orelse (self.hir_to_bir.module.types.voidType() catch 0);
                        const val = try self.lowerExpr(a.value);
                        if (val != NO_VALUE) {
                            try self.emitStore(ty, slot, val);
                        }
                        return NO_VALUE;
                    }
                },
                else => {},
            }
        }
        _ = try self.lowerExpr(a.value);
        return NO_VALUE;
    }

    fn lowerCall(self: *Builder, c: HirExpr.HirExprKind.CallExpr) LowerError!ValueId {
        const callee_expr = self.hir_to_bir.hir.getExpr(c.callee);
        if (callee_expr) |ce| {
            switch (ce.kind) {
                .path => |p| {
                    const owned_name = try std.fmt.allocPrint(self.alloc, "fn_{d}", .{p.def.index});
                    var args = std.ArrayList(ValueId).init(self.alloc);
                    defer args.deinit();
                    for (c.args) |arg| {
                        const val = try self.lowerExpr(arg);
                        if (val != NO_VALUE) {
                            try args.append(val);
                        }
                    }
                    const void_ty = self.hir_to_bir.builtinToBir(.void_type);
                    const owned_args = try self.alloc.dupe(ValueId, args.items);
                    return self.emitOp(.call, void_ty, &.{}, .{ .named_call = .{ .name = owned_name, .args = owned_args } });
                },
                else => {},
            }
        }
        _ = try self.lowerExpr(c.callee);
        for (c.args) |arg| {
            _ = try self.lowerExpr(arg);
        }
        return NO_VALUE;
    }
};
