const std = @import("std");
const Allocator = std.mem.Allocator;
const thir = @import("thir.zig");
const hir_arena = @import("../../frontend/hir/arena.zig");
const hir_expr = @import("../../frontend/hir/expr.zig");
const hir_stmt = @import("../../frontend/hir/stmt.zig");
const hir_item = @import("../../frontend/hir/item.zig");
const hir_body = @import("../../frontend/hir/body.zig");
const hir_literal = @import("../../frontend/hir/literal.zig");
const hir_pattern = @import("../../frontend/hir/pattern.zig");
const hir_ty = @import("../../frontend/hir/ty.zig");
const ids = @import("../../frontend/foundation/ids/ids.zig");
const type_sys = @import("../../frontend/type_system/type_system.zig");
const TypeEngine = type_sys.TypeEngine;
const SourceSpan = @import("../../frontend/source/location/span.zig").SourceSpan;

const HirExpr = hir_expr.HirExpr;
const HirStmt = hir_stmt.HirStmt;
const HirItem = hir_item.HirItem;
const HirBody = hir_body.HirBody;
const HirLiteral = hir_literal.HirLiteral;
const HirPattern = hir_pattern.HirPattern;
const HirBinOp = hir_expr.BinOp;
const HirUnOp = hir_expr.UnaryOp;

const HirExprId = ids.ExprId;
const HirStmtId = ids.StmtId;
const HirDefId = ids.DefId;
const HirTypeId = ids.TypeId;
const HirSymbolId = ids.SymbolId;
const HirItemId = ids.ItemId;
const HirBodyId = ids.BodyId;

const HirItemKind = hir_item.HirItem.HirItemKind;

// ─── IR Stores ───
pub const HirExprStore = std.ArrayList(HirExpr);
pub const HirStmtStore = std.ArrayList(HirStmt);
pub const HirItemStore = std.ArrayList(HirItem);
pub const HirBodyStore = std.ArrayList(HirBody);
pub const HirPatternStore = std.ArrayList(HirPattern);

// ─── Lowering Error ───
pub const LowerError = error{
    OutOfMemory,
    UnsupportedSyntax,
    UnresolvedName,
    MismatchedType,
};

// ─── Loop Context ───
const LoopContext = struct {
    break_block: thir.BlockId,
    continue_block: thir.BlockId,
    next: ?*const LoopContext = null,
};

// ─── Lowering Context ───
pub const LowerContext = struct {
    backing: Allocator,
    arena: *std.heap.ArenaAllocator,
    allocator: Allocator,
    module: *thir.ThirModule,
    type_engine: *TypeEngine,

    hir_exprs: *const HirExprStore,
    hir_patterns: *const HirPatternStore,
    stmts: *const HirStmtStore,
    items: *const HirItemStore,
    hir_bodies: *const HirBodyStore,

    // Map HIR DefId → THIR ValueId for variables and params
    def_to_value: std.AutoHashMap(HirDefId, thir.ValueId),

    // Current function being lowered
    func: ?*thir.ThirFunction = null,

    // Current block being built
    current_stmts: std.ArrayList(thir.ThirStmt),
    current_terminator: ?thir.BasicBlock.Terminator = null,

    // Block storage
    blocks: std.ArrayList(thir.BasicBlock),
    block_labels: std.ArrayList([]const u8),
    next_block_id: thir.BlockId = .{ .index = 0 },

    // Value arena
    values: std.ArrayList(thir.ValueDef),
    value_exprs: std.ArrayList(thir.ThirExpr),
    places: std.ArrayList(thir.PlaceDesc),

    // Loop context stack
    loop_ctx: ?*const LoopContext = null,

    pub fn init(
        backing: Allocator,
        module: *thir.ThirModule,
        engine: *TypeEngine,
        hir_exprs: *const HirExprStore,
        hir_patterns: *const HirPatternStore,
        stmts: *const HirStmtStore,
        items: *const HirItemStore,
        hir_bodies: *const HirBodyStore,
    ) LowerContext {
        const arena_ptr = backing.create(std.heap.ArenaAllocator) catch unreachable;
        arena_ptr.* = std.heap.ArenaAllocator.init(backing);
        const allocator = arena_ptr.allocator();
        return .{
            .backing = backing,
            .arena = arena_ptr,
            .allocator = allocator,
            .module = module,
            .type_engine = engine,
            .hir_exprs = hir_exprs,
            .hir_patterns = hir_patterns,
            .stmts = stmts,
            .items = items,
            .hir_bodies = hir_bodies,
            .def_to_value = std.AutoHashMap(HirDefId, thir.ValueId).init(allocator),
            .current_stmts = std.ArrayList(thir.ThirStmt).init(allocator),
            .blocks = std.ArrayList(thir.BasicBlock).init(allocator),
            .block_labels = std.ArrayList([]const u8).init(allocator),
            .values = std.ArrayList(thir.ValueDef).init(allocator),
            .value_exprs = std.ArrayList(thir.ThirExpr).init(allocator),
            .places = std.ArrayList(thir.PlaceDesc).init(allocator),
        };
    }

    pub fn deinit(self: *LowerContext) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }


    // ─── Value Allocation ───
    pub fn allocValue(self: *LowerContext, ty: ids.TypeId, storage: thir.Storage) !thir.ValueId {
        const id = thir.ValueId.new(@intCast(self.values.items.len));
        try self.values.append(.{ .ty = ty, .storage = storage, .expr = ids.ExprId.new(id.index) });
        try self.value_exprs.append(.{ .span = .{}, .ty = ty, .kind = .{ .none = {} } });
        return id;
    }

    pub fn setExpr(self: *LowerContext, vid: thir.ValueId, expr: thir.ThirExpr) !void {
        self.value_exprs.items[vid.index] = expr;
    }

    pub fn allocLocal(self: *LowerContext, ty: ids.TypeId, mutable: bool) !thir.ValueId {
        const id = try self.allocValue(ty, .stack);
        try self.places.append(.{ .ty = ty, .storage = .stack, .mutable = mutable, .span = .{} });
        return id;
    }

    // ─── Block Management ───
    pub fn startBlock(self: *LowerContext, label: []const u8) !thir.BlockId {
        const id = thir.BlockId.new(@intCast(self.blocks.items.len));
        try self.block_labels.append(label);
        try self.blocks.append(.{
            .label = label,
            .stmts = &.{},
            .terminator = .{ .diverge = {} },
        });
        self.current_stmts.clearRetainingCapacity();
        self.current_terminator = null;
        return id;
    }

    pub fn finishBlock(self: *LowerContext, id: thir.BlockId, term: thir.BasicBlock.Terminator) void {
        self.blocks.items[id.index].terminator = term;
        self.blocks.items[id.index].stmts = self.current_stmts.toOwnedSlice() catch unreachable;
    }

    // ─── Emit Statement ───
    pub fn emitStmt(self: *LowerContext, stmt: thir.ThirStmt) !void {
        try self.current_stmts.append(stmt);
    }

    // ─── Expression Lowering ───
    // Returns the ValueId of the result (or NO_VALUE for unit expressions).
    pub fn lowerExpr(self: *LowerContext, expr_id: HirExprId) LowerError!thir.ValueId {
        const expr = self.hir_exprs.items[expr_id.index];
        const ty = expr.ty;

        switch (expr.kind) {
            .literal => |lit| return self.lowerLiteral(lit.value, ty),
            .path => |p| return self.lowerPath(p),
            .binary => |b| return self.lowerBinary(b, ty),
            .unary => |u| return self.lowerUnary(u, ty),
            .call => |c| return self.lowerCall(c, ty),
            .method_call => |mc| return self.lowerMethodCall(mc, ty),
            .field => |f| return self.lowerField(f, ty),
            .index => |idx| return self.lowerIndex(idx, ty),
            .assign => |a| return self.lowerAssign(a),
            .if_expr => |if_e| return self.lowerIf(if_e, ty),
            .while_expr => |w| return self.lowerWhile(w, ty),
            .for_expr => |f| return self.lowerFor(f, ty),
            .loop_expr => |l| return self.lowerLoop(l, ty),
            .block => |b| return self.lowerBlock(b, ty),
            .return_expr => |r| return self.lowerReturn(r),
            .break_expr => |b| return self.lowerBreak(b),
            .continue_expr => |c| return self.lowerContinue(c),
            .type_cast => |tc| return self.lowerCast(tc, ty),
            .ref => |r| return self.lowerRef(r, ty),
            .deref => |d| return self.lowerDeref(d, ty),
            .closure => return LowerError.UnsupportedSyntax,
            .match_expr => |m| return self.lowerMatch(m, ty),
            .range => |r| return self.lowerRange(r, ty),
            .missing => return thir.NO_VALUE,
        }
    }

    // ─── Statement Lowering ───
    pub fn lowerStmt(self: *LowerContext, stmt_id: HirStmtId) LowerError!void {
        const stmt = self.stmts.items[stmt_id.index];

        switch (stmt.kind) {
            .local_decl => |ld| try self.lowerLocalDecl(ld, stmt.span),
            .expr => |es| {
                const val = try self.lowerExpr(es.expr);
                if (!val.eql(thir.NO_VALUE)) {
                    try self.emitStmt(.{
                        .span = stmt.span,
                        .kind = .{ .expr_stmt = .{ .expr = val } },
                    });
                }
            },
            .if_stmt => |is| try self.lowerIfStmt(is, stmt.span),
            .while_stmt => |ws| try self.lowerWhileStmt(ws, stmt.span),
            .for_stmt => |fs| try self.lowerForStmt(fs, stmt.span),
            .loop_stmt => |ls| try self.lowerLoopStmt(ls, stmt.span),
            .return_stmt => |rs| {
                const val = if (rs.value) |v| try self.lowerExpr(v) else null;
                try self.emitStmt(.{
                    .span = stmt.span,
                    .kind = .{ .return_stmt = .{ .value = val } },
                });
            },
            .break_stmt => |bs| {
                const val = if (bs.value) |v| try self.lowerExpr(v) else null;
                const loop_blk = self.loop_ctx.?.break_block;
                try self.emitStmt(.{
                    .span = stmt.span,
                    .kind = .{ .break_stmt = .{ .value = val, .target_loop = loop_blk } },
                });
            },
            .continue_stmt => |cs| {
                _ = cs;
                const loop_blk = self.loop_ctx.?.continue_block;
                try self.emitStmt(.{
                    .span = stmt.span,
                    .kind = .{ .continue_stmt = .{ .target_loop = loop_blk } },
                });
            },
            .block => |bs| {
                for (bs.stmts) |s| try self.lowerStmt(s);
            },
            .defer_stmt => return LowerError.UnsupportedSyntax,
            .errdefer_stmt => return LowerError.UnsupportedSyntax,
            .missing => {},
        }
    }

    // ─── Specific Lowerers ───

    fn lowerLiteral(self: *LowerContext, lit: HirLiteral, ty: ids.TypeId) !thir.ValueId {
        const val = try self.allocValue(ty, .local_reg);
        const thir_lit: thir.Literal = switch (lit) {
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .boolean => |v| .{ .bool_val = v },
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
        };
        try self.setExpr(val, .{ .span = .{}, .ty = ty, .kind = .{ .literal = thir_lit } });
        return val;
    }

    fn lowerPath(self: *LowerContext, path: HirExpr.HirExprKind.PathExpr) !thir.ValueId {
        if (self.def_to_value.get(path.def)) |var_vid| {
            const var_ty = self.values.items[var_vid.index].ty;
            const result = try self.allocValue(var_ty, .local_reg);
            try self.setExpr(result, .{ .span = .{}, .ty = var_ty, .kind = .{ .load = .{ .place = .{ .local = var_vid, .projections = &.{} } } } });
            return result;
        }
        // Unknown definition — produce a zero value as placeholder
        const val = try self.allocValue(.{ .index = 0 }, .local_reg);
        try self.setExpr(val, .{ .span = .{}, .ty = .{ .index = 0 }, .kind = .{ .literal = .{ .int = 0 } } });
        return val;
    }

    fn lowerBinary(self: *LowerContext, b: HirExpr.HirExprKind.BinaryExpr, ty: ids.TypeId) !thir.ValueId {
        const lhs = try self.lowerExpr(b.left);
        const rhs = try self.lowerExpr(b.right);
        const result = try self.allocValue(ty, .local_reg);
        const op = mapBinOp(b.op);
        try self.setExpr(result, .{ .span = .{}, .ty = ty, .kind = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } } });
        return result;
    }

    fn lowerUnary(self: *LowerContext, u: HirExpr.HirExprKind.UnaryExpr, ty: ids.TypeId) !thir.ValueId {
        const operand = try self.lowerExpr(u.operand);
        const result = try self.allocValue(ty, .local_reg);
        const op = mapUnOp(u.op);
        try self.setExpr(result, .{ .span = .{}, .ty = ty, .kind = .{ .unary = .{ .op = op, .operand = operand } } });
        return result;
    }

    fn lowerCall(self: *LowerContext, c: HirExpr.HirExprKind.CallExpr, ty: ids.TypeId) !thir.ValueId {
        var args = try self.allocator.alloc(thir.ValueId, c.args.len);
        for (c.args, 0..) |arg, i| {
            args[i] = try self.lowerExpr(arg);
        }

        const callee_expr = self.hir_exprs.items[c.callee.index];
        const func_def_id = switch (callee_expr.kind) {
            .path => |p| p.def,
            else => HirDefId{ .index = 0 },
        };

        const resolved_ty = if (ty.isValid()) ty else resolved: {
            var found = ty;
            for (self.items.items) |item| {
                switch (item.kind) {
                    .fn_decl => |f| {
                        if (f.def_id.eql(func_def_id)) {
                            found = f.return_type;
                            break;
                        }
                    },
                    .extern_fn => |e| {
                        if (e.def_id.eql(func_def_id)) {
                            found = e.return_type;
                            break;
                        }
                    },
                    else => {},
                }
            }
            break :resolved found;
        };

        const ret = if (resolved_ty.isValid())
            try self.allocValue(resolved_ty, .local_reg)
        else
            thir.NO_VALUE;

        if (!ret.eql(thir.NO_VALUE)) {
            try self.setExpr(ret, .{ .span = .{}, .ty = resolved_ty, .kind = .{ .call = .{ .func = .{ .function = func_def_id }, .args = args, .ret_ty = resolved_ty } } });
        }

        return ret;
    }

    fn lowerMethodCall(self: *LowerContext, mc: HirExpr.HirExprKind.MethodCallExpr, ty: ids.TypeId) !thir.ValueId {
        const object = try self.lowerExpr(mc.object);
        const call_args_len = mc.args.len + 1;
        var args = try self.allocator.alloc(thir.ValueId, call_args_len);
        args[0] = object;
        for (mc.args, 1..) |arg, i| {
            args[i] = try self.lowerExpr(arg);
        }

        const ret = if (ty.isValid())
            try self.allocValue(ty, .local_reg)
        else
            thir.NO_VALUE;

        if (!ret.eql(thir.NO_VALUE)) {
            try self.setExpr(ret, .{ .span = .{}, .ty = ty, .kind = .{ .call = .{ .func = .{ .function = mc.method }, .args = args, .ret_ty = ty } } });
        }

        return ret;
    }

    fn lowerField(self: *LowerContext, f: HirExpr.HirExprKind.FieldExpr, ty: ids.TypeId) !thir.ValueId {
        const object = try self.lowerExpr(f.object);
        const result = try self.allocValue(ty, .local_reg);
        try self.setExpr(result, .{ .span = .{}, .ty = ty, .kind = .{ .field_addr = .{ .object = object, .field_index = 0 } } });
        return result;
    }

    fn lowerIndex(self: *LowerContext, idx: HirExpr.HirExprKind.IndexExpr, ty: ids.TypeId) !thir.ValueId {
        const object = try self.lowerExpr(idx.object);
        const index = try self.lowerExpr(idx.index);
        const result = try self.allocValue(ty, .local_reg);
        try self.setExpr(result, .{ .span = .{}, .ty = ty, .kind = .{ .index_addr = .{ .object = object, .index = index } } });
        return result;
    }

    fn lowerAssign(self: *LowerContext, a: HirExpr.HirExprKind.AssignExpr) !thir.ValueId {
        const value = try self.lowerExpr(a.value);
        // target is a place — for now just emit the store
        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .assignment = .{
                .place = value,
                .value = value,
            } },
        });
        return thir.NO_VALUE;
    }

    fn lowerIf(self: *LowerContext, if_e: HirExpr.HirExprKind.IfExpr, ty: ids.TypeId) !thir.ValueId {
        // if as expression → phi-like merge
        const cond = try self.lowerExpr(if_e.condition);
        const then_blk = try self.startBlock("if.then");
        const else_blk = try self.startBlock("if.else");
        const merge_blk = try self.startBlock("if.merge");

        // terminator for current block
        self.finishBlock(thir.BlockId.new(@intCast(self.blocks.items.len - 3)), .{
            .cond_br = .{ .cond = cond, .then = then_blk, .else_ = else_blk },
        });

        // Lower then branch
        const then_val = try self.lowerExpr(if_e.then_branch);
        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .break_stmt = .{ .value = if (!then_val.eql(thir.NO_VALUE)) then_val else null, .target_loop = merge_blk } },
        });
        self.finishBlock(then_blk, .{ .br = merge_blk });

        // Lower else branch
        const else_val = try self.lowerExpr(if_e.else_branch);
        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .break_stmt = .{ .value = if (!else_val.eql(thir.NO_VALUE)) else_val else null, .target_loop = merge_blk } },
        });
        self.finishBlock(else_blk, .{ .br = merge_blk });

        // In merge block, result = phi
        const result_val = if (ty.isValid()) try self.allocValue(ty, .local_reg) else thir.NO_VALUE;
        return result_val;
    }

    fn lowerWhile(self: *LowerContext, w: HirExpr.HirExprKind.WhileExpr, ty: ids.TypeId) !thir.ValueId {
        const cond_blk = try self.startBlock("while.cond");
        const body_blk = try self.startBlock("while.body");
        const exit_blk = try self.startBlock("while.exit");

        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .block = .{ .block = cond_blk } },
        });
        self.finishBlock(thir.BlockId.new(@intCast(self.blocks.items.len - 4)), .{ .br = cond_blk });

        // cond check
        const cond = try self.lowerExpr(w.condition);
        self.finishBlock(cond_blk, .{ .cond_br = .{ .cond = cond, .then = body_blk, .else_ = exit_blk } });

        // body
        var ctx = LoopContext{ .break_block = exit_blk, .continue_block = cond_blk, .next = self.loop_ctx };
        self.loop_ctx = &ctx;
        _ = try self.lowerExpr(w.body);
        self.loop_ctx = ctx.next;
        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .continue_stmt = .{ .target_loop = cond_blk } },
        });
        self.finishBlock(body_blk, .{ .br = cond_blk });

        _ = ty;
        return thir.NO_VALUE;
    }

    fn lowerFor(self: *LowerContext, f: HirExpr.HirExprKind.ForExpr, ty: ids.TypeId) !thir.ValueId {
        // for = while with iterator
        // Simplified: lower body as a loop
        const body_blk = try self.startBlock("for.body");
        const exit_blk = try self.startBlock("for.exit");
        _ = try self.lowerExpr(f.iterable);

        var ctx = LoopContext{ .break_block = exit_blk, .continue_block = body_blk, .next = self.loop_ctx };
        self.loop_ctx = &ctx;
        _ = try self.lowerExpr(f.body);
        self.loop_ctx = ctx.next;
        self.finishBlock(body_blk, .{ .br = body_blk });

        _ = ty;
        _ = f.iter_var;
        return thir.NO_VALUE;
    }

    fn lowerLoop(self: *LowerContext, l: HirExpr.HirExprKind.LoopExpr, ty: ids.TypeId) !thir.ValueId {
        const body_blk = try self.startBlock("loop.body");
        const exit_blk = try self.startBlock("loop.exit");

        self.finishBlock(thir.BlockId.new(@intCast(self.blocks.items.len - 2)), .{ .br = body_blk });

        var ctx = LoopContext{ .break_block = exit_blk, .continue_block = body_blk, .next = self.loop_ctx };
        self.loop_ctx = &ctx;
        _ = try self.lowerExpr(l.body);
        self.loop_ctx = ctx.next;

        self.finishBlock(body_blk, .{ .br = body_blk });

        _ = ty;
        return thir.NO_VALUE;
    }

    fn lowerBlock(self: *LowerContext, b: HirExpr.HirExprKind.BlockExpr, ty: ids.TypeId) !thir.ValueId {
        for (b.stmts) |s| try self.lowerStmt(s);
        const result = try self.lowerExpr(b.result);
        _ = ty;
        return result;
    }

    fn lowerReturn(self: *LowerContext, r: HirExpr.HirExprKind.ReturnExpr) !thir.ValueId {
        const val = if (r.value.index != 0) try self.lowerExpr(r.value) else null;
        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .return_stmt = .{ .value = val } },
        });
        return thir.NO_VALUE;
    }

    fn lowerBreak(self: *LowerContext, b: HirExpr.HirExprKind.BreakExpr) !thir.ValueId {
        const val = if (b.value.index != 0) try self.lowerExpr(b.value) else null;
        const target = self.loop_ctx.?.break_block;
        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .break_stmt = .{ .value = val, .target_loop = target } },
        });
        return thir.NO_VALUE;
    }

    fn lowerContinue(self: *LowerContext, c: HirExpr.HirExprKind.ContinueExpr) !thir.ValueId {
        _ = c;
        const target = self.loop_ctx.?.continue_block;
        try self.emitStmt(.{
            .span = .{},
            .kind = .{ .continue_stmt = .{ .target_loop = target } },
        });
        return thir.NO_VALUE;
    }

    fn lowerCast(self: *LowerContext, tc: HirExpr.HirExprKind.TypeCastExpr, ty: ids.TypeId) !thir.ValueId {
        const operand = try self.lowerExpr(tc.operand);
        const result = try self.allocValue(ty, .local_reg);
        const from_ty = self.getValueType(operand);
        const cast_kind = self.classifyCast(from_ty, tc.target_type);
        try self.setExpr(result, .{ .span = .{}, .ty = ty, .kind = .{ .cast = .{ .kind = cast_kind, .operand = operand, .from_ty = from_ty, .to_ty = tc.target_type } } });
        return result;
    }

    fn lowerRef(self: *LowerContext, r: HirExpr.HirExprKind.RefExpr, ty: ids.TypeId) !thir.ValueId {
        const operand = try self.lowerExpr(r.operand);
        const result = try self.allocValue(ty, .local_reg);
        try self.setExpr(result, .{ .span = .{}, .ty = ty, .kind = .{ .addr_of = .{ .operand = operand, .mut = r.mutable } } });
        return result;
    }

    fn lowerDeref(self: *LowerContext, d: HirExpr.HirExprKind.DerefExpr, ty: ids.TypeId) !thir.ValueId {
        const operand = try self.lowerExpr(d.operand);
        const result = try self.allocValue(ty, .local_reg);
        try self.setExpr(result, .{ .span = .{}, .ty = ty, .kind = .{ .deref = .{ .operand = operand } } });
        return result;
    }

    fn lowerMatch(self: *LowerContext, m: HirExpr.HirExprKind.MatchExpr, ty: ids.TypeId) !thir.ValueId {
        // match → switch tree
        const scrutinee = try self.lowerExpr(m.scrutinee);
        const exit_blk = try self.startBlock("match.exit");
        _ = exit_blk;

        // Simplified: lower first arm only for now
        for (m.arms) |arm| {
            _ = try self.lowerExpr(arm.body);
            _ = arm.pattern;
            _ = arm.guard;
        }

        _ = scrutinee;
        _ = ty;
        return thir.NO_VALUE;
    }

    fn lowerRange(self: *LowerContext, r: HirExpr.HirExprKind.RangeExpr, ty: ids.TypeId) !thir.ValueId {
        _ = try self.lowerExpr(r.start);
        _ = try self.lowerExpr(r.end);
        _ = ty;
        return thir.NO_VALUE;
    }

    // ─── Statement Lowerers ───

    fn lowerLocalDecl(self: *LowerContext, ld: HirStmt.HirStmtKind.LocalDecl, span: SourceSpan) !void {
        const init_val = if (ld.init) |e| try self.lowerExpr(e) else thir.NO_VALUE;
        const mutable = ld.kind == .@"var" or ld.kind == .let;

        // Allocate the local
        const ty = if (ld.type_annotation) |t| t else ids.TypeId{ .index = 0 };
        const place_val = try self.allocLocal(ty, mutable);

        if (!init_val.eql(thir.NO_VALUE)) {
            try self.emitStmt(.{
                .span = span,
                .kind = .{ .let = .{
                    .place = place_val,
                    .init = init_val,
                    .storage = .stack,
                } },
            });
        }

        // Map the pattern's DefId to this THIR value
        const pat = self.hir_patterns.items[ld.pattern.index];
        if (pat.kind == .binding) {
            try self.def_to_value.put(pat.kind.binding.def, place_val);
        }
    }

    fn lowerIfStmt(self: *LowerContext, is: HirStmt.HirStmtKind.IfStmt, span: SourceSpan) !void {
        const cond = try self.lowerExpr(is.condition);
        const then_blk = try self.startBlock("if.then");
        const else_blk = try self.startBlock("if.else");
        const merge_blk = try self.startBlock("if.end");

        self.finishBlock(thir.BlockId.new(@intCast(self.blocks.items.len - 4)), .{
            .cond_br = .{ .cond = cond, .then = then_blk, .else_ = else_blk },
        });

        // then
        try self.lowerStmt(is.then_branch);
        try self.emitStmt(.{ .span = span, .kind = .{ .break_stmt = .{ .value = null, .target_loop = merge_blk } } });
        self.finishBlock(then_blk, .{ .br = merge_blk });

        // else
        if (is.else_branch) |else_s| {
            try self.lowerStmt(else_s);
        }
        try self.emitStmt(.{ .span = span, .kind = .{ .break_stmt = .{ .value = null, .target_loop = merge_blk } } });
        self.finishBlock(else_blk, .{ .br = merge_blk });
    }

    fn lowerWhileStmt(self: *LowerContext, ws: HirStmt.HirStmtKind.WhileStmt, span: SourceSpan) !void {
        const cond_blk = try self.startBlock("while.cond");
        const body_blk = try self.startBlock("while.body");
        const exit_blk = try self.startBlock("while.exit");

        self.finishBlock(thir.BlockId.new(@intCast(self.blocks.items.len - 4)), .{ .br = cond_blk });

        const cond = try self.lowerExpr(ws.condition);
        self.finishBlock(cond_blk, .{ .cond_br = .{ .cond = cond, .then = body_blk, .else_ = exit_blk } });

        var ctx = LoopContext{ .break_block = exit_blk, .continue_block = cond_blk, .next = self.loop_ctx };
        self.loop_ctx = &ctx;
        try self.lowerStmt(ws.body);
        self.loop_ctx = ctx.next;
        try self.emitStmt(.{ .span = span, .kind = .{ .continue_stmt = .{ .target_loop = cond_blk } } });
        self.finishBlock(body_blk, .{ .br = cond_blk });
    }

    fn lowerForStmt(self: *LowerContext, fs: HirStmt.HirStmtKind.ForStmt, span: SourceSpan) !void {
        const body_blk = try self.startBlock("for.body");
        const exit_blk = try self.startBlock("for.exit");
        _ = try self.lowerExpr(fs.iterable);

        var ctx = LoopContext{ .break_block = exit_blk, .continue_block = body_blk, .next = self.loop_ctx };
        self.loop_ctx = &ctx;
        try self.lowerStmt(fs.body);
        self.loop_ctx = ctx.next;
        try self.emitStmt(.{ .span = span, .kind = .{ .continue_stmt = .{ .target_loop = body_blk } } });
        self.finishBlock(body_blk, .{ .br = body_blk });
        _ = fs.iter_var;
    }

    fn lowerLoopStmt(self: *LowerContext, ls: HirStmt.HirStmtKind.LoopStmt, span: SourceSpan) !void {
        const body_blk = try self.startBlock("loop.body");
        const exit_blk = try self.startBlock("loop.exit");

        self.finishBlock(thir.BlockId.new(@intCast(self.blocks.items.len - 2)), .{ .br = body_blk });

        var ctx = LoopContext{ .break_block = exit_blk, .continue_block = body_blk, .next = self.loop_ctx };
        self.loop_ctx = &ctx;
        try self.lowerStmt(ls.body);
        self.loop_ctx = ctx.next;
        try self.emitStmt(.{ .span = span, .kind = .{ .continue_stmt = .{ .target_loop = body_blk } } });
        self.finishBlock(body_blk, .{ .br = body_blk });
    }

    // ─── Item Lowering ───

    pub fn lowerItem(self: *LowerContext, item_idx: u32) !void {
        const item = self.items.items[item_idx];
        switch (item.kind) {
            .fn_decl => |f| try self.lowerFnDecl(f, item.span),
            .struct_item => |s| try self.lowerStructItem(s),
            .enum_item => |e| try self.lowerEnumItem(e),
            .const_item => |c| {
                _ = try self.lowerExpr(c.init);
            },
            .state_item, .kernel_item => {}, // Handled by domain-specific passes
            .impl_item => |impl_item| {
                for (impl_item.methods) |method| {
                    try self.lowerFnDecl(method, item.span);
                }
            },
            else => {},
        }
    }

    fn lowerFnDecl(self: *LowerContext, f: HirItemKind.FnItem, span: SourceSpan) !void {
        var params = try self.allocator.alloc(thir.ThirFunction.Param, f.params.len);
        for (f.params, 0..) |p, i| {
            params[i] = .{
                .name = p.name,
                .def_id = p.def_id,
                .ty = p.ty,
                .storage = .stack,
            };
        }

        const name_str = try self.allocator.dupe(u8, f.name_bytes);
        var func = thir.ThirFunction{
            .name = f.name,
            .name_str = name_str,
            .def_id = f.def_id,
            .params = params,
            .return_type = f.return_type,
            .body = null,
            .linkage = .internal,
        };

        self.func = &func;
        self.blocks.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        self.value_exprs.clearRetainingCapacity();
        self.places.clearRetainingCapacity();
        self.current_stmts.clearRetainingCapacity();
        self.def_to_value.clearRetainingCapacity();

        // Create THIR values for parameters (SSA, not stack slots)
        for (func.params) |param| {
            const param_val = try self.allocValue(param.ty, .local_reg);
            try self.def_to_value.put(param.def_id, param_val);
        }

        // Lower body
        const entry_blk = try self.startBlock("entry");
        const fb = self.hir_bodies.items[f.body.index];
        const result_val = try self.lowerExpr(fb.entry);
        const return_val: ?thir.ValueId = if (result_val.isValid()) result_val else null;
        self.finishBlock(entry_blk, .{ .return_ret = .{ .value = return_val } });

        // Build the body
        func.body = .{
            .blocks = self.blocks.toOwnedSlice() catch unreachable,
            .entry = entry_blk,
            .values = self.values.toOwnedSlice() catch unreachable,
            .exprs = self.value_exprs.toOwnedSlice() catch unreachable,
            .places = self.places.toOwnedSlice() catch unreachable,
        };

        _ = span;
        _ = try self.module.addFunction(func);
    }

    fn lowerStructItem(self: *LowerContext, s: HirItemKind.StructItem) !void {
        var fields = try self.allocator.alloc(thir.ThirStruct.Field, s.fields.len);
        for (s.fields, 0..) |f, i| {
            fields[i] = .{ .name = f.name, .ty = f.ty };
        }
        try self.module.structs.append(.{
            .name = s.name,
            .def_id = s.def_id,
            .fields = fields,
        });
    }

    fn lowerEnumItem(self: *LowerContext, e: HirItemKind.EnumItem) !void {
        var variants = try self.allocator.alloc(thir.ThirEnum.Variant, e.variants.len);
        for (e.variants, 0..) |v, i| {
            var fields = try self.allocator.alloc(thir.ThirStruct.Field, v.fields.len);
            for (v.fields, 0..) |f, j| {
                fields[j] = .{ .name = f.name, .ty = f.ty };
            }
            variants[i] = .{ .name = v.name, .fields = fields, .tag = @intCast(i) };
        }
        try self.module.enums.append(.{
            .name = e.name,
            .def_id = e.def_id,
            .variants = variants,
        });
    }

    // ─── Op Mapping ───

    fn mapBinOp(op: HirBinOp) thir.BinOp {
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
            .and_ => .and_,
            .or_ => .or_,
            .bitwise_and => .bitwise_and,
            .bitwise_or => .bitwise_or,
            .bitwise_xor => .bitwise_xor,
            .shl => .shl,
            .shr => .shr,
        };
    }

    fn mapUnOp(op: HirUnOp) thir.UnOp {
        return switch (op) {
            .negate => .negate,
            .not => .not,
            .bitwise_not => .bitwise_not,
            else => unreachable,
        };
    }

    fn getValueType(self: *LowerContext, value: thir.ValueId) ids.TypeId {
        if (value.isValid() and value.index < self.values.items.len) {
            return self.values.items[value.index].ty;
        }
        return .{ .index = 0 };
    }

    fn classifyCast(self: *LowerContext, from: ids.TypeId, to: ids.TypeId) thir.CastKind {
        const from_resolved = self.type_engine.resolve(from);
        const to_resolved = self.type_engine.resolve(to);
        const from_data = self.type_engine.get(from_resolved);
        const to_data = self.type_engine.get(to_resolved);

        if (from_data == null or to_data == null) return .bitcast;
        const fd = from_data.?;
        const td = to_data.?;

        return switch (fd) {
            .builtin => |fb| switch (td) {
                .builtin => |tb| classifyBuiltinCast(fb, tb),
                .pointer => .pointer_cast,
                else => .bitcast,
            },
            .pointer => switch (td) {
                .pointer => .pointer_cast,
                .builtin => .pointer_to_int,
                else => .bitcast,
            },
            .slice => switch (td) {
                .pointer => .pointer_cast,
                else => .bitcast,
            },
            .array => switch (td) {
                .pointer => .pointer_cast,
                .slice => .unsize,
                else => .bitcast,
            },
            .reference => switch (td) {
                .pointer => .pointer_cast,
                else => .bitcast,
            },
            else => .bitcast,
        };
    }

    fn classifyBuiltinCast(from: type_sys.BuiltinKind, to: type_sys.BuiltinKind) thir.CastKind {
        if (from == to) return .bitcast;

        const from_is_int = builtinIsSignedInt(from) or builtinIsUnsignedInt(from);
        const to_is_int = builtinIsSignedInt(to) or builtinIsUnsignedInt(to);
        const from_is_float = builtinIsFloat(from);
        const to_is_float = builtinIsFloat(to);

        if (from_is_int and to_is_int) {
            const fb = builtinBitWidth(from);
            const tb = builtinBitWidth(to);
            if (tb > fb) {
                if (builtinIsSignedInt(from) and builtinIsSignedInt(to)) return .int_extend_signed;
                if (builtinIsUnsignedInt(from) and builtinIsUnsignedInt(to)) return .int_extend_unsigned;
                return .int_extend_unsigned;
            }
            if (tb < fb) return .int_truncate;
            return .bitcast;
        }

        if (from_is_int and to_is_float) {
            return if (builtinIsUnsignedInt(from)) .uint_to_float else .int_to_float;
        }

        if (from_is_float and to_is_int) {
            return if (builtinIsUnsignedInt(to)) .float_to_uint else .float_to_int;
        }

        if (from_is_float and to_is_float) {
            const fb = builtinBitWidth(from);
            const tb = builtinBitWidth(to);
            if (tb > fb) return .float_extend;
            if (tb < fb) return .float_truncate;
            return .bitcast;
        }

        if (from == .bool_type and to_is_int) return .bool_to_int;
        if (from_is_int and to == .bool_type) return .int_to_bool;

        return .bitcast;
    }

    fn builtinIsSignedInt(k: type_sys.BuiltinKind) bool {
        return switch (k) {
            .i8_type, .i16_type, .i32_type, .i64_type => true,
            else => false,
        };
    }

    fn builtinIsUnsignedInt(k: type_sys.BuiltinKind) bool {
        return switch (k) {
            .u8_type, .u16_type, .u32_type, .u64_type => true,
            else => false,
        };
    }

    fn builtinIsFloat(k: type_sys.BuiltinKind) bool {
        return switch (k) {
            .f32_type, .f64_type => true,
            else => false,
        };
    }

    fn builtinBitWidth(k: type_sys.BuiltinKind) u32 {
        return switch (k) {
            .bool_type => 1,
            .i8_type, .u8_type, .char_type => 8,
            .i16_type, .u16_type => 16,
            .i32_type, .u32_type, .f32_type => 32,
            .i64_type, .u64_type, .f64_type => 64,
            .void_type, .never_type, .str_type => 0,
        };
    }
};
