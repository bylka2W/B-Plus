const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../frontend/ast.zig");
const bir = @import("bir.zig");
const bir_types = @import("bir_types.zig");
const TypeId = bir_types.TypeId;
const ScalarKind = bir_types.ScalarKind;

const Op = bir.Op;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const NO_VALUE = bir.NO_VALUE;
const Inst = bir.Inst;

const BIRError = error{ TypeError, UnknownExpression, OutOfMemory };

var t_void: TypeId = bir_types.INVALID_TYPE;
var t_i1: TypeId = bir_types.INVALID_TYPE;
var t_i8: TypeId = bir_types.INVALID_TYPE;
var t_i16: TypeId = bir_types.INVALID_TYPE;
var t_i32: TypeId = bir_types.INVALID_TYPE;
var t_i64: TypeId = bir_types.INVALID_TYPE;
var t_u8: TypeId = bir_types.INVALID_TYPE;
var t_u16: TypeId = bir_types.INVALID_TYPE;
var t_u32: TypeId = bir_types.INVALID_TYPE;
var t_u64: TypeId = bir_types.INVALID_TYPE;
var t_f32: TypeId = bir_types.INVALID_TYPE;
var t_f64: TypeId = bir_types.INVALID_TYPE;
var t_ptr: TypeId = bir_types.INVALID_TYPE;

fn ensureTypes(module: *bir.Module) !void {
    if (t_void == bir_types.INVALID_TYPE) {
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

fn mapType(module: *bir.Module, type_name: []const u8) !TypeId {
    if (std.mem.eql(u8, type_name, "void")) return t_void;
    if (std.mem.eql(u8, type_name, "bool")) return t_i1;
    if (std.mem.eql(u8, type_name, "i8")) return t_i8;
    if (std.mem.eql(u8, type_name, "i16")) return t_i16;
    if (std.mem.eql(u8, type_name, "i32")) return t_i32;
    if (std.mem.eql(u8, type_name, "i64") or std.mem.eql(u8, type_name, "int")) return t_i64;
    if (std.mem.eql(u8, type_name, "u8")) return t_u8;
    if (std.mem.eql(u8, type_name, "u16")) return t_u16;
    if (std.mem.eql(u8, type_name, "u32")) return t_u32;
    if (std.mem.eql(u8, type_name, "u64")) return t_u64;
    if (std.mem.eql(u8, type_name, "f32")) return t_f32;
    if (std.mem.eql(u8, type_name, "f64")) return t_f64;
    if (std.mem.eql(u8, type_name, "string")) return t_ptr;
    if (std.mem.eql(u8, type_name, "ptr")) return t_ptr;
    const owned = try module.allocator.dupe(u8, type_name);
    return module.types.add(.{ .custom_opaque = owned });
}

pub fn lowerProgram(allocator: Allocator, program: *const ast.ProgramNode) !bir.Module {
    var module = bir.Module.init(allocator);
    errdefer module.deinit();
    for (program.common.func_defs.items) |func| {
        try lowerFunction(allocator, &module, func);
    }
    if (program.plan.states.items.len > 0) {
        try lowerStateMachine(allocator, &module, program.plan.states.items);
    }
    return module;
}

fn makeInst(allocator: Allocator, op: Op, ty: TypeId, ops: []const ValueId, data: Inst.Data) !Inst {
    var owned_ops: []ValueId = &.{};
    if (ops.len > 0) {
        owned_ops = try allocator.dupe(ValueId, ops);
    }
    return .{ .op = op, .ty = ty, .result = NO_VALUE, .operands = owned_ops, .data = data };
}

const VarInfo = struct {
    value: ValueId,
    type_id: TypeId,
    is_param: bool = false,
};

/// Infer function return type from its body's return statements.
/// Pre-scans body lines for `return expr` and uses simple literal inference.
/// Falls back to t_i64 (B+ default) if no return found or can't infer.
fn inferReturnType(module: *bir.Module, func: ast.EntryDecl) TypeId {
    _ = module;
    for (func.body_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "return")) continue;
        const rest = std.mem.trim(u8, trimmed["return".len..], " \t\r\n");
        if (rest.len == 0) continue; // bare `return` → void, keep scanning
        // String literal
        if (rest[0] == '"') return t_ptr;
        // Boolean literals
        if (std.mem.eql(u8, rest, "true") or std.mem.eql(u8, rest, "false")) return t_i1;
        // Numeric literal
        var is_num = true;
        var has_dot = false;
        for (rest, 0..) |ch, i| {
            if (i == 0 and (ch == '-' or ch == '+')) continue;
            if (ch == '.') { if (has_dot) { is_num = false; break; } has_dot = true; continue; }
            if (ch < '0' or ch > '9') { is_num = false; break; }
        }
        if (is_num and rest.len > 0) {
            return if (has_dot) t_f64 else t_i64;
        }
        // For variables/expressions/function calls, default to i64
        return t_i64;
    }
    return t_void;
}

fn lowerFunction(
    allocator: Allocator,
    module: *bir.Module,
    func: ast.EntryDecl,
) !void {
    try ensureTypes(module);
    // B+ design: return type is optional. Infer from return expressions if not declared.
    const ret_type = if (func.return_type) |rt| try mapType(module, rt) else inferReturnType(module, func);
    const func_id = try module.addFunction(func.name, ret_type, .internal);

    {
        const fn_mut = module.getFunctionMut(func_id);
        const owned_params = try allocator.alloc(bir.FuncParam, func.params.items.len);
        const owned_values = try allocator.alloc(ValueId, func.params.items.len);
        for (func.params.items, 0..) |param, i| {
            owned_params[i] = .{ .name = try allocator.dupe(u8, param.name), .ty = try mapType(module, param.type_name) };
            owned_values[i] = try fn_mut.createValue();
        }
        fn_mut.params = owned_params;
        fn_mut.param_values = owned_values;
    }

    const entry_id = try module.addBlock(func_id, "entry");
    var b = Builder{
        .alloc = allocator,
        .mod = module,
        .fid = func_id,
        .blk = entry_id,
        .vars = std.StringHashMap(VarInfo).init(allocator),
        .ret_type = ret_type,
        .func_return_types = std.StringHashMap(TypeId).init(allocator),
        .loop_stack = std.ArrayList(LoopCtx).init(allocator),
    };
    defer b.vars.deinit();
    defer b.func_return_types.deinit();
    defer b.loop_stack.deinit();

    for (func.params.items, 0..) |param, i| {
        const param_ty = try mapType(module, param.type_name);
        const pval = module.getFunction(func_id).param_values[i];
        try b.vars.put(param.name, .{ .value = pval, .type_id = param_ty, .is_param = true });
        {
            const fn_mut = module.getFunctionMut(func_id);
            const owned_name = try allocator.dupe(u8, param.name);
            try fn_mut.value_debug_names.put(pval, owned_name);
        }
    }

    var body_joined = std.ArrayList(u8).init(allocator);
    defer body_joined.deinit();
    for (func.body_lines.items, 0..) |line, i| {
        if (i > 0) try body_joined.append(';');
        try body_joined.appendSlice(line);
    }
    if (body_joined.items.len > 0) try lowerBodyStr(&b, body_joined.items, ';');
    if (!b.terminated()) try b.retVoid();
}

fn lowerStateMachine(
    allocator: Allocator,
    module: *bir.Module,
    states: []const ast.StateDefNode,
) !void {
    try ensureTypes(module);

    var sm = try module.addStateMachine("plan", @intCast(states.len));

    for (states, 0..) |state, si| {
        const entry_fn = try lowerStateEntry(allocator, module, state);
        const exit_fn = try lowerStateExit(allocator, module, state);
        try sm.states.append(.{
            .name = try allocator.dupe(u8, state.name),
            .entry_fn = entry_fn,
            .exit_fn = exit_fn,
            .variables_count = @intCast(state.variables.items.len),
        });
        for (state.transitions.items) |t| {
            const target_idx = blk: {
                for (states, 0..) |s, ti| {
                    if (std.mem.eql(u8, s.name, t.target)) break :blk @as(u32, @intCast(ti));
                }
                break :blk 0;
            };

            var event_id: u32 = 0;
            if (t.is_always) {
                event_id = 0;
            } else if (t.event_name) |ename| {
                if (sm.event_id_map.get(ename)) |existing| {
                    event_id = existing;
                } else {
                    event_id = @intCast(sm.event_names.items.len);
                    try sm.event_names.append(try allocator.dupe(u8, ename));
                    try sm.event_id_map.put(sm.event_names.items[event_id], event_id);
                }
            }

            const guard_fn: ?bir.FunctionId = null;
            var guard_expr_owned: ?[]const u8 = null;
            if (t.guard) |guard_expr| {
                guard_expr_owned = try allocator.dupe(u8, guard_expr);
            }

            var action_fn: ?bir.FunctionId = null;
            if (t.body) |action_body| {
                const act_name = try std.fmt.allocPrint(allocator, "action_{s}_{s}", .{ state.name, t.target });
                defer allocator.free(act_name);
                const afid = try module.addFunction(act_name, t_void, .internal);
                const aeid = try module.addBlock(afid, "entry");
                var ab = Builder{
                    .alloc = allocator,
                    .mod = module,
                    .fid = afid,
                    .blk = aeid,
                    .vars = std.StringHashMap(VarInfo).init(allocator),
                    .ret_type = t_void,
                    .func_return_types = std.StringHashMap(TypeId).init(allocator),
                    .loop_stack = std.ArrayList(LoopCtx).init(allocator),
                };
                defer ab.vars.deinit();
                defer ab.func_return_types.deinit();
                defer ab.loop_stack.deinit();
                try lowerBodyStr(&ab, action_body, ';');
                if (!ab.terminated()) try ab.retVoid();
                action_fn = afid;
            }

            try sm.transitions.append(.{
                .event_id = event_id,
                .from_state_idx = @intCast(si),
                .to_state_idx = target_idx,
                .guard_fn = guard_fn,
                .action_fn = action_fn,
                .guard_expr = guard_expr_owned,
            });
        }
    }
}

fn lowerStateEntry(
    allocator: Allocator,
    module: *bir.Module,
    state: ast.StateDefNode,
) !bir.FunctionId {
    try ensureTypes(module);
    const nm = try std.fmt.allocPrint(allocator, "state_{s}_entry", .{state.name});
    defer allocator.free(nm);
    const fid = try module.addFunction(nm, t_void, .entry);
    const eid = try module.addBlock(fid, "entry");
    var b = Builder{
        .alloc = allocator,
        .mod = module,
        .fid = fid,
        .blk = eid,
        .vars = std.StringHashMap(VarInfo).init(allocator),
        .ret_type = t_void,
        .func_return_types = std.StringHashMap(TypeId).init(allocator),
        .loop_stack = std.ArrayList(LoopCtx).init(allocator),
    };
    defer b.vars.deinit();
    defer b.func_return_types.deinit();
    defer b.loop_stack.deinit();

    for (state.variables.items) |v| {
        const resolved_type = v.type_name orelse blk: {
            // Auto-infer from default value (B+ rules: int → i64, float → f64)
            if (v.default_value) |dv| {
                if (dv.len > 0) {
                    var is_num = true;
                    var has_dot = false;
                    for (dv, 0..) |ch, i| {
                        if (i == 0 and (ch == '-' or ch == '+')) continue;
                        if (ch == '.') { if (has_dot) { is_num = false; break; } has_dot = true; continue; }
                        if (ch < '0' or ch > '9') { is_num = false; break; }
                    }
                    if (is_num) break :blk if (has_dot) "f64" else "i64";
                    if (dv[0] == '"') break :blk "string";
                    if (std.mem.eql(u8, dv, "true") or std.mem.eql(u8, dv, "false")) break :blk "bool";
                }
            }
            break :blk "i64";
        };
        const vt = try mapType(module, resolved_type);
        const slot = try b.emitOp(.alloca, vt, &.{}, .{ .none = {} });
        try b.vars.put(v.name, .{ .value = slot, .type_id = vt });
        if (v.default_value) |dv| {
            const val = try lowerExpr(&b, dv);
            if (val != NO_VALUE) try b.emitStore(vt, slot, val);
        }
    }
    if (state.enter_body) |body| {
        try lowerBodyStr(&b, body, ';');
    }
    if (!b.terminated()) try b.retVoid();
    return fid;
}

fn lowerStateExit(
    allocator: Allocator,
    module: *bir.Module,
    state: ast.StateDefNode,
) !?bir.FunctionId {
    try ensureTypes(module);
    const body = state.exit_body orelse return null;
    const tb = std.mem.trim(u8, body, " \t\r\n");
    if (tb.len == 0) return null;

    const nm = try std.fmt.allocPrint(allocator, "state_{s}_exit", .{state.name});
    defer allocator.free(nm);
    const fid = try module.addFunction(nm, t_void, .internal);
    const eid = try module.addBlock(fid, "entry");
    var b = Builder{
        .alloc = allocator,
        .mod = module,
        .fid = fid,
        .blk = eid,
        .vars = std.StringHashMap(VarInfo).init(allocator),
        .ret_type = t_void,
        .func_return_types = std.StringHashMap(TypeId).init(allocator),
        .loop_stack = std.ArrayList(LoopCtx).init(allocator),
    };
    defer b.vars.deinit();
    defer b.func_return_types.deinit();
    defer b.loop_stack.deinit();
    try lowerBodyStr(&b, tb, ';');
    if (!b.terminated()) try b.retVoid();
    return fid;
}

const LoopCtx = struct {
    header_id: BlockId,
    exit_id: BlockId,
};

const Builder = struct {
    alloc: Allocator,
    mod: *bir.Module,
    fid: bir.FunctionId,
    blk: BlockId,
    vars: std.StringHashMap(VarInfo),
    ret_type: TypeId,
    func_return_types: std.StringHashMap(TypeId),
    loop_stack: std.ArrayList(LoopCtx),

    fn terminated(self: *Builder) bool {
        const bl = self.mod.getFunctionMut(self.fid).getBlock(self.blk);
        if (bl.instrs.items.len == 0) return false;
        const last = bl.instrs.items[bl.instrs.items.len - 1];
        return last.op == .ret or last.op == .br or last.op == .cond_br;
    }

    fn emitOp(self: *Builder, op: Op, ty: TypeId, ops: []const ValueId, data: Inst.Data) !ValueId {
        return self.mod.addInst(self.fid, self.blk, try makeInst(self.alloc, op, ty, ops, data));
    }

    fn emitRet(self: *Builder, val: ValueId, ty: TypeId) !void {
        if (val != NO_VALUE) {
            _ = try self.emitOp(.ret, ty, &.{val}, .{ .none = {} });
        } else {
            _ = try self.emitOp(.ret, t_void, &.{}, .{ .none = {} });
        }
    }

    fn retVoid(self: *Builder) !void {
        _ = try self.emitOp(.ret, t_void, &.{}, .{ .none = {} });
    }

    fn emitBr(self: *Builder, target: BlockId) !void {
        _ = try self.emitOp(.br, t_void, &.{}, .{ .block_target = target });
    }

    fn emitCondBr(self: *Builder, cond: ValueId, then_b: BlockId, else_b: BlockId) !void {
        _ = try self.emitOp(.cond_br, t_void, &.{cond}, .{ .cond_branch = .{ .cond = cond, .then_block = then_b, .else_block = else_b } });
    }

    fn emitStore(self: *Builder, ty: TypeId, slot: ValueId, val: ValueId) !void {
        _ = try self.emitOp(.store, ty, &.{ slot, val }, .{ .none = {} });
    }

    fn emitLoad(self: *Builder, slot: ValueId, ty: TypeId) !ValueId {
        return self.emitOp(.load, ty, &.{slot}, .{ .none = {} });
    }

    fn emitAlloca(self: *Builder, ty: TypeId) !ValueId {
        return self.emitOp(.alloca, ty, &.{}, .{ .none = {} });
    }

    fn emitConstInt(self: *Builder, v: i64) !ValueId {
        return self.emitOp(.@"const", t_i64, &.{}, .{ .const_data = .{ .int = v } });
    }

    fn emitConstFloat(self: *Builder, v: f64) !ValueId {
        return self.emitOp(.@"const", t_f64, &.{}, .{ .const_data = .{ .float = v } });
    }

    fn emitConstBool(self: *Builder, v: bool) !ValueId {
        return self.emitOp(.@"const", t_i1, &.{}, .{ .const_data = .{ .bool = v } });
    }

    fn emitConstStr(self: *Builder, s: []const u8) !ValueId {
        const owned = try self.alloc.dupe(u8, s);
        return self.emitOp(.@"const", t_ptr, &.{}, .{ .string = owned });
    }

    fn emitBinOp(self: *Builder, op: Op, lty: TypeId, rty: TypeId, l: ValueId, r: ValueId) !ValueId {
        if (lty != rty) {
            std.log.err("type mismatch: binary operand types must match (got different types)", .{});
            return BIRError.TypeError;
        }
        return self.emitOp(op, lty, &.{ l, r }, .{ .none = {} });
    }

    fn emitNeg(self: *Builder, val: ValueId, ty: TypeId) !ValueId {
        if (ty == t_f32 or ty == t_f64) return BIRError.TypeError;
        const zero = try self.emitConstInt(0);
        return self.emitBinOp(.sub, ty, ty, zero, val);
    }

    fn emitCall(self: *Builder, name: []const u8, args: []const ValueId) !ValueId {
        const ret_ty = self.func_return_types.get(name) orelse t_void;
        const owned_name = try self.alloc.dupe(u8, name);
        const owned_args = try self.alloc.dupe(ValueId, args);
        return self.emitOp(.call, ret_ty, &.{}, .{ .named_call = .{ .name = owned_name, .args = owned_args } });
    }

    fn getVar(self: *Builder, name: []const u8) ?VarInfo {
        return self.vars.get(name);
    }

    fn newBlock(self: *Builder, label: []const u8) !BlockId {
        return self.mod.addBlock(self.fid, label);
    }
};

/// Resolve the correct BIR Op for a binary operation based on operand types.
/// Returns the BIR op or error if the operation is not valid for the given types.
fn resolveBinOp(op_str: []const u8, ty: TypeId) !Op {
    const is_float = (ty == t_f32 or ty == t_f64);
    const is_int = (ty == t_i64 or ty == t_i32 or ty == t_i16 or ty == t_i8 or
        ty == t_u64 or ty == t_u32 or ty == t_u16 or ty == t_u8);
    const is_bool = (ty == t_i1);

    if (std.mem.eql(u8, op_str, "+")) {
        if (is_int) return .add;
        if (is_float) return .fadd;
    }
    if (std.mem.eql(u8, op_str, "-")) {
        if (is_int) return .sub;
        if (is_float) return .fsub;
    }
    if (std.mem.eql(u8, op_str, "*")) {
        if (is_int) return .mul;
        if (is_float) return .fmul;
    }
    if (std.mem.eql(u8, op_str, "/")) {
        if (is_int) return .div;
        if (is_float) return .fdiv;
    }
    if (std.mem.eql(u8, op_str, "%")) {
        if (is_int) return .mod;
        if (is_float) return .fmod;
    }
    if (std.mem.eql(u8, op_str, "==")) {
        if (is_int or is_bool) return .eq;
        if (is_float) return .feq;
    }
    if (std.mem.eql(u8, op_str, "!=")) {
        if (is_int or is_bool) return .ne;
        if (is_float) return .fne;
    }
    if (std.mem.eql(u8, op_str, "<=")) {
        if (is_int) return .le;
        if (is_float) return .fle;
    }
    if (std.mem.eql(u8, op_str, ">=")) {
        if (is_int) return .ge;
        if (is_float) return .fge;
    }
    if (std.mem.eql(u8, op_str, "<")) {
        if (is_int) return .lt;
        if (is_float) return .flt;
    }
    if (std.mem.eql(u8, op_str, ">")) {
        if (is_int) return .gt;
        if (is_float) return .fgt;
    }
    if (std.mem.eql(u8, op_str, "&&")) {
        if (is_bool) return .and_op;
    }
    if (std.mem.eql(u8, op_str, "||")) {
        if (is_bool) return .or_op;
    }
    std.log.err("type mismatch: operator '{s}' is not valid for this type", .{op_str});
    return BIRError.TypeError;
}

fn inferExprType(b: *Builder, expr: []const u8) !TypeId {
    const t = std.mem.trim(u8, expr, " \t\r\n");
    if (t.len == 0) return t_void;

    if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false")) return t_i1;

    if (t[0] == '"') return t_ptr;

    if (std.ascii.isDigit(t[0]) or (t.len > 1 and t[0] == '-' and std.ascii.isDigit(t[1]))) {
        if (std.mem.indexOfScalar(u8, t, '.') != null) return t_f64;
        return t_i64;
    }

    if (t[0] == '(') {
        if (findParenEnd(t, 0)) |end| {
            if (end == t.len - 1) return try inferExprType(b, t[1..end]);
        }
    }

    if (std.mem.indexOfScalar(u8, t, '(')) |pp| {
        if (pp > 0) {
            const nm = std.mem.trim(u8, t[0..pp], " \t\r\n");
            if (b.func_return_types.get(nm)) |ret_ty| return ret_ty;
            if (std.mem.eql(u8, nm, "print")) return t_void;
            if (std.mem.eql(u8, nm, "malloc")) return t_ptr;
            if (std.mem.eql(u8, nm, "addr")) return t_ptr;
        }
    }

    const cmp_ops = [_][]const u8{ "==", "!=", "<=", ">=", "<", ">" };
    for (cmp_ops) |op| {
        if (findBinOp(t, op)) |_| return t_i1;
    }

    const bool_ops = [_][]const u8{ "&&", "||" };
    for (bool_ops) |op| {
        if (findBinOp(t, op)) |_| return t_i1;
    }

    const arop_ops = [_]struct { []const u8, TypeId }{
        .{ "+", t_i64 }, .{ "-", t_i64 }, .{ "*", t_i64 },
        .{ "/", t_i64 }, .{ "%", t_i64 },
    };
    for (arop_ops) |pair| {
        if (findBinOp(t, pair[0])) |parts| {
            const lty = try inferExprType(b, parts.left);
            const rty = try inferExprType(b, parts.right);
            if (lty == rty) return lty;
            std.log.err("type mismatch: incompatible types in binary operation (different types must match in B+)", .{});
            return BIRError.TypeError;
        }
    }

    if (t[0] == '-' and t.len > 1) return try inferExprType(b, t[1..]);

    if (b.getVar(t)) |vi| return vi.type_id;

    return t_i64;
}

fn lowerStmt(b: *Builder, line: []const u8) anyerror!void {
    if (b.terminated()) return;

    if (std.mem.startsWith(u8, line, "return")) {
        const rest = std.mem.trim(u8, line["return".len..], " \t\r\n");
        if (rest.len == 0) {
            try b.retVoid();
        } else {
            const val = try lowerExpr(b, rest);
            const ty = try inferExprType(b, rest);
            try b.emitRet(val, ty);
        }
        return;
    }

    if (std.mem.startsWith(u8, line, "var ")) {
        const rest = std.mem.trim(u8, line["var ".len..], " \t\r\n");
        const name = extractName(rest);
        if (name.len == 0) return;

        var var_type: TypeId = t_i64;
        if (extractVarType(rest)) |vt| {
            var_type = try mapType(b.mod, vt);
        }

        const slot = try b.emitAlloca(var_type);
        try b.vars.put(name, .{ .value = slot, .type_id = var_type });
        {
            const fn_mut = b.mod.getFunctionMut(b.fid);
            const owned_name = try b.alloc.dupe(u8, name);
            try fn_mut.value_debug_names.put(slot, owned_name);
        }

        if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
            const expr_str = std.mem.trim(u8, rest[eq + 1 ..], " \t\r\n");
            const val = try lowerExpr(b, expr_str);
            if (val != NO_VALUE) {
                const expr_ty = try inferExprType(b, expr_str);
                const store_ty = if (expr_ty != t_i64) expr_ty else var_type;
                try b.emitStore(store_ty, slot, val);
            }
        }
        return;
    }

    if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "if(")) {
        try lowerIf(b, line);
        return;
    }

    if (std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "while(")) {
        try lowerWhile(b, line);
        return;
    }

    if (std.mem.startsWith(u8, line, "for ") or std.mem.startsWith(u8, line, "for(")) {
        try lowerFor(b, line);
        return;
    }

    if (std.mem.eql(u8, line, "break")) {
        try lowerBreak(b);
        return;
    }

    if (std.mem.eql(u8, line, "continue")) {
        try lowerContinue(b);
        return;
    }

    if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
        const lhs = std.mem.trim(u8, line[0..eq_idx], " \t\r\n");
        const rhs = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r\n");
        if (lhs.len > 0 and rhs.len > 0) {
            // Check if this is a type annotation: name:type = value
            if (std.mem.indexOfScalar(u8, lhs, ':')) |colon_idx| {
                const var_name = std.mem.trim(u8, lhs[0..colon_idx], " \t\r\n");
                const type_name = std.mem.trim(u8, lhs[colon_idx + 1 ..], " \t\r\n");
                if (var_name.len > 0 and type_name.len > 0) {
                    const var_type = try mapType(b.mod, type_name);
                    const slot = try b.emitAlloca(var_type);
                    try b.vars.put(var_name, .{ .value = slot, .type_id = var_type });
                    {
                        const fn_mut = b.mod.getFunctionMut(b.fid);
                        const owned_name = try b.alloc.dupe(u8, var_name);
                        try fn_mut.value_debug_names.put(slot, owned_name);
                    }
                    const val = try lowerExpr(b, rhs);
                    if (val != NO_VALUE) {
                        const expr_ty = try inferExprType(b, rhs);
                        const store_ty = if (expr_ty != t_i64) expr_ty else var_type;
                        try b.emitStore(store_ty, slot, val);
                    }
                    return;
                }
            }
            // Auto-infer: if variable doesn't exist, create it with inferred type
            if (b.getVar(lhs) == null) {
                const val = try lowerExpr(b, rhs);
                const inferred_type = try inferExprType(b, rhs);
                const slot = try b.emitAlloca(inferred_type);
                try b.vars.put(lhs, .{ .value = slot, .type_id = inferred_type });
                {
                    const fn_mut = b.mod.getFunctionMut(b.fid);
                    const owned_name = try b.alloc.dupe(u8, lhs);
                    try fn_mut.value_debug_names.put(slot, owned_name);
                }
                if (val != NO_VALUE) try b.emitStore(inferred_type, slot, val);
                return;
            }
            if (b.getVar(lhs)) |vi| {
                const val = try lowerExpr(b, rhs);
                const expr_ty = try inferExprType(b, rhs);
                const store_ty = if (expr_ty != t_i64) expr_ty else vi.type_id;
                try b.emitStore(store_ty, vi.value, val);
            }
        }
        return;
    }

    _ = try lowerExpr(b, line);
}

fn lowerExpr(b: *Builder, expr: []const u8) anyerror!ValueId {
    const t = std.mem.trim(u8, expr, " \t\r\n");
    if (t.len == 0) return NO_VALUE;

    if (std.mem.eql(u8, t, "true")) return b.emitConstBool(true);
    if (std.mem.eql(u8, t, "false")) return b.emitConstBool(false);

    if (t[0] == '"') {
        const eq = std.mem.lastIndexOfScalar(u8, t, '"') orelse t.len;
        return b.emitConstStr(t[1..eq]);
    }

    if (std.ascii.isDigit(t[0]) or (t.len > 1 and t[0] == '-' and std.ascii.isDigit(t[1]))) {
        var is_valid_number = true;
        var seen_dot = false;
        for (t, 0..) |c, i| {
            if (i == 0 and c == '-') continue;
            if (c == '.') {
                if (seen_dot) {
                    is_valid_number = false;
                    break;
                }
                seen_dot = true;
                continue;
            }
            if (!std.ascii.isDigit(c)) {
                is_valid_number = false;
                break;
            }
        }
        if (is_valid_number) {
            if (seen_dot) {
                return b.emitConstFloat(try std.fmt.parseFloat(f64, t));
            }
            return b.emitConstInt(try std.fmt.parseInt(i64, t, 10));
        }
    }

    if (t[0] == '(') {
        if (findParenEnd(t, 0)) |end| {
            if (end == t.len - 1) return lowerExpr(b, t[1..end]);
        }
    }

    if (std.mem.indexOfScalar(u8, t, '(')) |pp| {
        if (pp > 0) {
            const nm = std.mem.trim(u8, t[0..pp], " \t\r\n");
            if (findParenEnd(t, pp)) |c| {
                if (c == t.len - 1) return lowerCallExpr(b, nm, std.mem.trim(u8, t[pp + 1 .. c], " \t\r\n"));
            }
        }
    }

    const op_strs = [_][]const u8{ "+", "-", "*", "/", "%", "==", "!=", "<=", ">=", "<", ">", "&&", "||" };
    for (op_strs) |op_str| {
        if (findBinOp(t, op_str)) |parts| {
            const l = try lowerExpr(b, parts.left);
            const r = try lowerExpr(b, parts.right);
            const lty = try inferExprType(b, parts.left);
            const rty = try inferExprType(b, parts.right);
            // Both operands must have the same type
            if (lty != rty) {
                std.log.err("type mismatch: binary operand types must match (got different types)", .{});
                return BIRError.TypeError;
            }
            // Resolve correct BIR op for the type
            const bir_op = try resolveBinOp(op_str, lty);
            return b.emitOp(bir_op, lty, &.{ l, r }, .{ .none = {} });
        }
    }

    if (t[0] == '-' and t.len > 1) {
        const inner = try lowerExpr(b, t[1..]);
        const ty = try inferExprType(b, t[1..]);
        return b.emitNeg(inner, ty);
    }

    if (b.getVar(t)) |vi| {
        if (vi.is_param) return vi.value;
        return b.emitLoad(vi.value, vi.type_id);
    }

    std.log.err("error: unrecognized expression '{s}' in BIR lowering", .{t});
    return BIRError.UnknownExpression;
}

fn lowerCallExpr(b: *Builder, name: []const u8, args_str: []const u8) anyerror!ValueId {
    // Handle print built-in: dispatch to print_i64 (int) or print_str (string)
    const callee_name = if (std.mem.eql(u8, name, "print")) blk: {
        const trimmed = std.mem.trim(u8, args_str, " \t\r\n");
        break :blk if (trimmed.len > 0 and trimmed[0] == '"') "print_str" else "print_i64";
    } else name;

    var args = std.ArrayList(ValueId).init(b.alloc);
    defer args.deinit();
    if (args_str.len > 0) {
        var depth: i32 = 0;
        var in_str = false;
        var start: usize = 0;
        for (args_str, 0..) |c, i| {
            if (c == '"') in_str = !in_str;
            if (in_str) continue;
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (c == ',' and depth == 0) {
                const a = std.mem.trim(u8, args_str[start..i], " \t\r\n");
                if (a.len > 0) {
                    const v = try lowerExpr(b, a);
                    if (v != NO_VALUE) try args.append(v);
                }
                start = i + 1;
            }
        }
        const last = std.mem.trim(u8, args_str[start..], " \t\r\n");
        if (last.len > 0) {
            const v = try lowerExpr(b, last);
            if (v != NO_VALUE) try args.append(v);
        }
    }
    return b.emitCall(callee_name, args.items);
}

fn lowerIf(b: *Builder, line: []const u8) anyerror!void {
    const rest = std.mem.trim(u8, line[3..], " \t\r\n");
    const cb = findBraceBlock(rest) orelse return;
    const cond_str = std.mem.trim(u8, rest[0..cb.body_start - 1], " \t\r\n");
    const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

    const cond_val = try lowerExpr(b, cond_str);
    if (cond_val == NO_VALUE) return;

    const then_id = try b.newBlock("if_then");
    const else_id = try b.newBlock("if_else");

    try b.emitCondBr(cond_val, then_id, else_id);

    // Lower then body
    b.blk = then_id;
    try lowerBodyStr(b, body_str, ';');
    const then_term = b.terminated();

    // Lower else body
    b.blk = else_id;
    const after_body = std.mem.trim(u8, rest[cb.body_end + 1 ..], " \t\r\n");
    if (after_body.len > 0 and std.mem.startsWith(u8, after_body, "else")) {
        const else_rest = after_body["else".len..];
        const trimmed_else = std.mem.trim(u8, else_rest, " \t\r\n");
        if (trimmed_else.len > 0 and std.mem.startsWith(u8, trimmed_else, "if ")) {
            try lowerIf(b, trimmed_else);
        } else {
            if (findBraceBlock(trimmed_else)) |else_cb| {
                const else_body = std.mem.trim(u8, trimmed_else[else_cb.body_start..else_cb.body_end], " \t\r\n");
                try lowerBodyStr(b, else_body, ';');
            }
        }
    }
    const else_term = b.terminated();

    if (then_term and else_term) {
        // Both branches terminate — no merge needed, no continuation
        // Point b.blk to a terminated block so no more code is emitted
        b.blk = else_id;
    } else if (then_term and !else_term) {
        // Only then terminates — else needs to jump to merge
        const merge_id = try b.newBlock("if_merge");
        try b.emitBr(merge_id);
        b.blk = merge_id;
    } else if (!then_term and else_term) {
        // Only else terminates — then needs to jump to merge
        const merge_id = try b.newBlock("if_merge");
        b.blk = then_id;
        try b.emitBr(merge_id);
        b.blk = merge_id;
    } else {
        // Neither terminates — both jump to merge
        const merge_id = try b.newBlock("if_merge");
        b.blk = then_id;
        try b.emitBr(merge_id);
        b.blk = else_id;
        try b.emitBr(merge_id);
        b.blk = merge_id;
    }
}

fn lowerWhile(b: *Builder, line: []const u8) anyerror!void {
    const rest = std.mem.trim(u8, line[6..], " \t\r\n");
    const cb = findBraceBlock(rest) orelse return;
    const cond_str = std.mem.trim(u8, rest[0..cb.body_start - 1], " \t\r\n");
    const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

    const header_id = try b.newBlock("while_header");
    const body_id = try b.newBlock("while_body");
    const exit_id = try b.newBlock("while_exit");

    try b.emitBr(header_id);

    b.blk = header_id;
    const cond_val = try lowerExpr(b, cond_str);
    if (cond_val == NO_VALUE) return;
    try b.emitCondBr(cond_val, body_id, exit_id);

    //пушим контекст цикла чтобы break/continue знали куда прыгать
    try b.loop_stack.append(.{ .header_id = header_id, .exit_id = exit_id });
    defer _ = b.loop_stack.pop();

    b.blk = body_id;
    try lowerBodyStr(b, body_str, ';');
    if (!b.terminated()) try b.emitBr(header_id);

    b.blk = exit_id;
}

fn lowerFor(b: *Builder, line: []const u8) anyerror!void {
    //for i = 0; i < n; i = i + 1 { body }
    const rest = std.mem.trim(u8, line[4..], " \t\r\n");
    const cb = findBraceBlock(rest) orelse return;
    const header_str = std.mem.trim(u8, rest[0..cb.body_start - 1], " \t\r\n");
    const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

    //разбиваем по точке с запятой: init; cond; update
    var parts: [3][]const u8 = .{ "", "", "" };
    var part_idx: usize = 0;
    var depth: i32 = 0;
    var start: usize = 0;
    var in_str = false;
    for (header_str, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (in_str) continue;
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c == ';' and depth == 0 and part_idx < 3) {
            parts[part_idx] = std.mem.trim(u8, header_str[start..i], " \t\r\n");
            part_idx += 1;
            start = i + 1;
        }
    }
    if (part_idx < 3) parts[part_idx] = std.mem.trim(u8, header_str[start..], " \t\r\n");

    const init_str = parts[0];
    const cond_str = parts[1];
    const update_str = parts[2];

    //init
    if (init_str.len > 0) try lowerStmt(b, init_str);

    const header_id = try b.newBlock("for_header");
    const body_id = try b.newBlock("for_body");
    const update_id = try b.newBlock("for_update");
    const exit_id = try b.newBlock("for_exit");

    try b.emitBr(header_id);

    //условие
    b.blk = header_id;
    if (cond_str.len > 0) {
        const cond_val = try lowerExpr(b, cond_str);
        if (cond_val == NO_VALUE) return;
        try b.emitCondBr(cond_val, body_id, exit_id);
    } else {
        try b.emitBr(body_id);
    }

    //тело цикла
    try b.loop_stack.append(.{ .header_id = update_id, .exit_id = exit_id });
    defer _ = b.loop_stack.pop();

    b.blk = body_id;
    try lowerBodyStr(b, body_str, ';');
    if (!b.terminated()) try b.emitBr(update_id);

    //update
    b.blk = update_id;
    if (update_str.len > 0) try lowerStmt(b, update_str);
    if (!b.terminated()) try b.emitBr(header_id);

    b.blk = exit_id;
}

fn lowerBreak(b: *Builder) anyerror!void {
    if (b.loop_stack.items.len == 0) {
        std.log.err("break вне цикла", .{});
        return BIRError.TypeError;
    }
    const ctx = b.loop_stack.items[b.loop_stack.items.len - 1];
    try b.emitBr(ctx.exit_id);
}

fn lowerContinue(b: *Builder) anyerror!void {
    if (b.loop_stack.items.len == 0) {
        std.log.err("continue вне цикла", .{});
        return BIRError.TypeError;
    }
    const ctx = b.loop_stack.items[b.loop_stack.items.len - 1];
    try b.emitBr(ctx.header_id);
}

fn lowerBodyStr(b: *Builder, body: []const u8, sep: u8) anyerror!void {
    var pos: usize = 0;
    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\r' or body[pos] == '\n')) : (pos += 1) {}
        if (pos >= body.len) break;
        if (body[pos] == '{' or body[pos] == '}') {
            pos += 1;
            continue;
        }

        var depth: i32 = 0;
        var in_str = false;
        var start = pos;
        while (pos < body.len) {
            const c = body[pos];
            if (c == '"') in_str = !in_str;
            if (in_str) {
                pos += 1;
                continue;
            }
            if (c == '(' or c == '{') depth += 1;
            if (c == ')' or c == '}') {
                depth -= 1;
                if (depth < 0) {
                    pos += 1;
                    break;
                }
            }
            if (c == sep and depth == 0) {
                var stmt = std.mem.trim(u8, body[start..pos], " \t\r\n");
                pos += 1;
                start = pos;
                //для for/while/if
                const is_ctrl = stmt.len > 2 and (std.mem.startsWith(u8, stmt, "for ") or std.mem.startsWith(u8, stmt, "for(") or std.mem.startsWith(u8, stmt, "while ") or std.mem.startsWith(u8, stmt, "while(") or std.mem.startsWith(u8, stmt, "if ") or std.mem.startsWith(u8, stmt, "if("));
                if (is_ctrl) {
                    var brace_depth: i32 = 0;
                    for (stmt) |ch| { if (ch == '{') brace_depth += 1; if (ch == '}') brace_depth -= 1; }
                    var found_open = std.mem.indexOfScalar(u8, stmt, '{') != null;
                    while (pos < body.len) {
                        if (found_open and brace_depth <= 0) break;
                        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\r' or body[pos] == '\n')) : (pos += 1) {}
                        if (pos >= body.len) break;
                        const part_start = pos;
                        while (pos < body.len) {
                            const c2 = body[pos];
                            if (c2 == '"') in_str = !in_str;
                            if (in_str) { pos += 1; continue; }
                            if (c2 == '(' or c2 == '{') { depth += 1; brace_depth += 1; }
                            if (c2 == ')' or c2 == '}') { depth -= 1; brace_depth -= 1; }
                            if (c2 == sep and depth == 0) break;
                            pos += 1;
                        }
                        const part = std.mem.trim(u8, body[part_start..pos], " \t\r\n");
                        if (part.len > 0) stmt = std.mem.concat(b.alloc, u8, &.{ stmt, ";", part }) catch stmt;
                        if (!found_open) found_open = std.mem.indexOfScalar(u8, stmt, '{') != null;
                        if (found_open and brace_depth <= 0) break;
                        if (pos < body.len and body[pos] == sep) { pos += 1; }
                    }
                }
                if (stmt.len > 0) try lowerStmt(b, stmt);
                break;
            }
            pos += 1;
        }
        if (pos >= body.len or (pos == body.len)) {
            if (start < body.len) {
                const stmt = std.mem.trim(u8, body[start..body.len], " \t\r\n");
                if (stmt.len > 0) try lowerStmt(b, stmt);
            }
            break;
        }
    }
}

const BraceBlock = struct { body_start: usize, body_end: usize };

fn findBraceBlock(text: []const u8) ?BraceBlock {
    var i: usize = 0;
    while (i < text.len and text[i] != '{') : (i += 1) {}
    if (i >= text.len) return null;
    const body_start = i + 1;
    var depth: i32 = 1;
    i = body_start;
    while (i < text.len and depth > 0) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') depth -= 1;
        i += 1;
    }
    return .{ .body_start = body_start, .body_end = i - 1 };
}

const BinParts = struct { left: []const u8, right: []const u8 };

fn findBinOp(expr: []const u8, op: []const u8) ?BinParts {
    var depth: i32 = 0;
    var i: usize = expr.len;
    while (i > 0) {
        i -= 1;
        if (expr[i] == ')') depth += 1;
        if (expr[i] == '(') depth -= 1;
        if (depth != 0) continue;
        if (i + op.len > expr.len) continue;
        if (!std.mem.eql(u8, expr[i .. i + op.len], op)) continue;
        if (i == 0) return null;
        if (i + op.len >= expr.len) return null;
        if (std.mem.eql(u8, op, "=") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "!") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "<") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, ">") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "&") and i + 1 < expr.len and expr[i + 1] == '&') continue;
        if (std.mem.eql(u8, op, "|") and i + 1 < expr.len and expr[i + 1] == '|') continue;
        const left = std.mem.trim(u8, expr[0..i], " \t\r\n");
        const right = std.mem.trim(u8, expr[i + op.len ..], " \t\r\n");
        if (left.len > 0 and right.len > 0) return .{ .left = left, .right = right };
    }
    return null;
}

fn findParenEnd(line: []const u8, open: usize) ?usize {
    if (open >= line.len or line[open] != '(') return null;
    var depth: i32 = 0;
    var i = open;
    while (i < line.len) {
        if (line[i] == '(') depth += 1;
        if (line[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        if (line[i] == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) {}
        }
        i += 1;
    }
    return null;
}

fn extractName(rest: []const u8) []const u8 {
    const t = std.mem.trim(u8, rest, " \t\r\n");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isAlphanumeric(t[end]) or t[end] == '_')) : (end += 1) {}
    return t[0..end];
}

fn extractVarType(rest: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, rest, " \t\r\n");
    const colon_idx = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const after_colon = std.mem.trim(u8, t[colon_idx + 1 ..], " \t\r\n");
    var end: usize = 0;
    while (end < after_colon.len and std.ascii.isAlphanumeric(after_colon[end])) : (end += 1) {}
    if (end == 0) return null;
    const type_str = std.mem.trimRight(u8, after_colon[0..end], " \t\r\n");
    if (type_str.len == 0) return null;
    return type_str;
}
