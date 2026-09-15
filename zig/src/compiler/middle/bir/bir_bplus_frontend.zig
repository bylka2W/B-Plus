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

const FieldInfo = struct { type_id: TypeId, offset: u32 };

const StructLayout = struct {
    type_id: TypeId,
    fields: std.StringHashMap(FieldInfo),
};

const PtrInfo = struct {
    access_ty: TypeId,
    inner: ?[]const u8 = null,
};

const LValue = struct { addr: ValueId, ty: TypeId };

var g_struct_registry: std.StringHashMap(StructLayout) = undefined;
var g_struct_registry_ready: bool = false;
var g_func_param_types: std.StringHashMap(std.ArrayList(TypeId)) = undefined;
var g_func_param_ready: bool = false;

fn ptrInfoKey(b: *Builder, name: []const u8) ![]const u8 {
    return b.alloc.dupe(u8, name);
}

fn isAggregate(mod: *bir.Module, ty: TypeId) bool {
    return switch (mod.types.get(ty).kind) {
        .struct_type, .array => true,
        else => false,
    };
}

fn isArrayType(mod: *bir.Module, ty: TypeId) bool {
    return switch (mod.types.get(ty).kind) {
        .array => true,
        else => false,
    };
}

fn isFloatType(mod: *bir.Module, ty: TypeId) bool {
    return switch (mod.types.get(ty).kind) {
        .scalar => |sk| sk == .f32 or sk == .f64,
        else => false,
    };
}

fn isIntScalarType(mod: *bir.Module, ty: TypeId) bool {
    return switch (mod.types.get(ty).kind) {
        .scalar => |sk| switch (sk) {
            .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            else => false,
        },
        else => false,
    };
}

fn isSignedInt(text: []const u8) bool {
    if (text.len == 0) return false;
    var start: usize = 0;
    if (text[0] == '-') start = 1;
    if (start >= text.len) return false;
    for (text[start..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn normalizedAggregateType(mod: *bir.Module, ty: TypeId) TypeId {
    _ = mod;
    if (ty == t_i8 or ty == t_i16 or ty == t_i32 or
        ty == t_u8 or ty == t_u16 or ty == t_u32) return t_i64;
    return ty;
}

fn constIntOfExpr(b: *Builder, expr: []const u8) ?i64 {
    const t = std.mem.trim(u8, expr, " \t\r\n");
    if (t.len == 0) return null;
    if (t.len >= 2 and t[0] == '(' and t[t.len - 1] == ')') return constIntOfExpr(b, t[1 .. t.len - 1]);
    if (isSignedInt(t)) return std.fmt.parseInt(i64, t, 10) catch null;
    if (b.const_vals.get(t)) |v| return v;
    return null;
}

const IntRange = struct { min: i64, max: i64 };

fn intRange(ty: TypeId) ?IntRange {
    if (ty == t_i8) return .{ .min = -128, .max = 127 };
    if (ty == t_u8) return .{ .min = 0, .max = 255 };
    if (ty == t_i16) return .{ .min = -32768, .max = 32767 };
    if (ty == t_u16) return .{ .min = 0, .max = 65535 };
    if (ty == t_i32) return .{ .min = -2147483648, .max = 2147483647 };
    if (ty == t_u32) return .{ .min = 0, .max = 4294967295 };
    return null;
}

fn isNumericOrFloat(mod: *bir.Module, ty: TypeId) bool {
    return isIntScalarType(mod, ty) or isFloatType(mod, ty);
}

fn checkAssignableToVar(b: *Builder, var_ty: TypeId, expr_ty: TypeId) bool {
    if (var_ty == expr_ty) return true;
    if (isAggregate(b.mod, var_ty) or isAggregate(b.mod, expr_ty)) return true;
    if (expr_ty == t_i64 and isNumericOrFloat(b.mod, var_ty)) return true;
    if (isFloatType(b.mod, var_ty) and isNumericOrFloat(b.mod, expr_ty)) return true;
    if (isIntScalarType(b.mod, expr_ty) and isIntScalarType(b.mod, var_ty)) return true;
    return false;
}

fn plistTypeName(ty: TypeId) []const u8 {
    if (ty == t_i8) return "i8";
    if (ty == t_i16) return "i16";
    if (ty == t_i32) return "i32";
    if (ty == t_i64) return "i64";
    if (ty == t_u8) return "u8";
    if (ty == t_u16) return "u16";
    if (ty == t_u32) return "u32";
    if (ty == t_u64) return "u64";
    if (ty == t_f32) return "f32";
    if (ty == t_f64) return "f64";
    if (ty == t_ptr) return "string";
    return "unknown";
}

fn lookupStructByType(b: *Builder, ty: TypeId) ?*const StructLayout {
    _ = b;
    var it = g_struct_registry.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.type_id == ty) return entry.value_ptr;
    }
    return null;
}

fn lookupStructByField(b: *Builder, field: []const u8) ?*const StructLayout {
    _ = b;
    var it = g_struct_registry.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.fields.contains(field)) return entry.value_ptr;
    }
    return null;
}

fn splitTopLevel(alloc: Allocator, text: []const u8, seps: []const u8) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).init(alloc);
    var depth: i32 = 0;
    var in_str = false;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == '(' or c == '{') depth += 1;
        if (c == ')' or c == '}') depth -= 1;
        var is_sep = false;
        for (seps) |s| {
            if (s == c) {
                is_sep = true;
                break;
            }
        }
        if (is_sep and depth == 0) {
            const part = std.mem.trim(u8, text[start..i], " \t\r\n");
            if (part.len > 0) try out.append(part);
            start = i + 1;
        }
    }
    const last = std.mem.trim(u8, text[start..], " \t\r\n");
    if (last.len > 0) try out.append(last);
    return out;
}

fn structNameLiteral(b: *Builder, text: []const u8) ?[]const u8 {
    _ = b;
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 or t[t.len - 1] != '}') return null;
    const open = std.mem.indexOfScalar(u8, t, '{') orelse return null;
    const name = std.mem.trim(u8, t[0..open], " \t\r\n");
    if (name.len == 0) return null;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    if (!g_struct_registry_ready) return null;
    if (g_struct_registry.get(name)) |_| return name;
    return null;
}

fn lookLikeDotted(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    var i: usize = 0;
    while (i < t.len and (std.ascii.isAlphanumeric(t[i]) or t[i] == '_')) : (i += 1) {}
    return i + 1 < t.len and t[i] == '.';
}

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
    if (g_struct_registry_ready) {
        if (g_struct_registry.get(type_name)) |sl| return sl.type_id;
    }
    const owned = try module.allocator.dupe(u8, type_name);
    return module.types.add(.{ .custom_opaque = owned });
}

var g_enum_registry: std.StringHashMap(std.ArrayList(EntryEnumMember)) = undefined;
var g_enum_registry_ready: bool = false;

const EntryEnumMember = struct { name: []const u8, idx: i64 };

fn getEnumIndex(name: []const u8) ?i64 {
    if (!g_enum_registry_ready) return null;
    var it = g_enum_registry.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |m| {
            if (std.mem.eql(u8, m.name, name)) return m.idx;
        }
    }
    return null;
}

fn getEnumMember(enum_name: []const u8, member: []const u8) ?i64 {
    if (!g_enum_registry_ready) return null;
    if (g_enum_registry.get(enum_name)) |members| {
        for (members.items) |m| {
            if (std.mem.eql(u8, m.name, member)) return m.idx;
        }
    }
    return null;
}

fn buildEnumRegistry(allocator: Allocator, program: *const ast.ProgramNode) !void {
    g_enum_registry = std.StringHashMap(std.ArrayList(EntryEnumMember)).init(allocator);
    g_enum_registry_ready = true;
    for (program.metal.enums.items) |en| {
        var members = std.ArrayList(EntryEnumMember).init(allocator);
        for (en.members.items, 0..) |mem_name, i| {
            try members.append(.{ .name = try allocator.dupe(u8, mem_name), .idx = @intCast(i) });
        }
        try g_enum_registry.put(en.name, members);
    }
}

fn resolvePatternValue(b: *Builder, text: []const u8) !ValueId {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.fmt.parseInt(i64, trimmed, 10)) |v| {
        return b.emitConstInt(v);
    } else |_| {}
    if (lookLikeDotted(trimmed)) {
        if (std.mem.lastIndexOf(u8, trimmed, ".")) |dot| {
            const enum_name = std.mem.trim(u8, trimmed[0..dot], " \t\r\n");
            const member = std.mem.trim(u8, trimmed[dot + 1 ..], " \t\r\n");
            if (getEnumMember(enum_name, member)) |idx| {
                return b.emitConstInt(idx);
            }
        }
    }
    if (getEnumIndex(trimmed)) |idx| {
        return b.emitConstInt(idx);
    }
    std.log.err("error: unknown pattern '{s}'", .{trimmed});
    return BIRError.UnknownExpression;
}

fn splitArms(arms_text: []const u8) std.ArrayList(ArmInfo) {
    var arms = std.ArrayList(ArmInfo).init(std.heap.page_allocator);
    var remaining = std.mem.trim(u8, arms_text, " \t\r\n;");
    while (remaining.len > 0) {
        remaining = std.mem.trimLeft(u8, remaining, " \t\r\n;");
        if (remaining.len == 0 or remaining[0] == '}') break;
        if (std.mem.indexOf(u8, remaining, "=>")) |arrow_pos| {
            const pat = std.mem.trim(u8, remaining[0..arrow_pos], " \t\r\n;");
            var rest = std.mem.trimLeft(u8, remaining[arrow_pos + 2 ..], " \t\r\n;");
            var act_end = rest.len;
            if (std.mem.indexOfScalar(u8, rest, ';')) |ni| act_end = ni;
            const act = std.mem.trim(u8, rest[0..act_end], " \t\r\n");
            arms.append(.{ .pattern = pat, .action = act, .action_is_block = false }) catch {};
            remaining = std.mem.trimLeft(u8, rest[act_end..], " \t\r\n;");
        } else if (std.mem.indexOfScalar(u8, remaining, '{')) |brace_start| {
            const pat = std.mem.trim(u8, remaining[0..brace_start], " \t\r\n;");
            if (findBraceBlock(remaining[brace_start..])) |cb| {
                const body = std.mem.trim(u8, remaining[brace_start + cb.body_start + 1 .. brace_start + cb.body_end], " \t\r\n;");
                arms.append(.{ .pattern = pat, .action = body, .action_is_block = true }) catch {};
                remaining = std.mem.trimLeft(u8, remaining[brace_start + cb.body_end + 1 ..], " \t\r\n;");
            } else {
                break;
            }
        } else {
            break;
        }
    }
    return arms;
}

const ArmInfo = struct { pattern: []const u8, action: []const u8, action_is_block: bool };

fn lowerMatch(b: *Builder, rest: []const u8) anyerror!void {
    const trimmed = std.mem.trim(u8, rest, " \t\r\n");
    const brace_idx = std.mem.indexOfScalar(u8, trimmed, '{');
    if (brace_idx) |bi| {
        const scrut_text = std.mem.trim(u8, trimmed[0..bi], " \t\r\n;");
        const scrut_val = try lowerExpr(b, scrut_text);
        const arms_text = std.mem.trim(u8, trimmed[bi + 1 ..], " \t\r\n;");
        if (arms_text.len == 0 or arms_text[arms_text.len - 1] != '}') {
            return;
        }
        var arm_list = splitArms(arms_text);
        defer arm_list.deinit();
        const exit_id = try b.newBlock("match_exit");
        for (arm_list.items, 0..) |arm, ai| {
            const arm_block = try b.newBlock("match_arm");
            const pat_val = try resolvePatternValue(b, arm.pattern);
            const cmp_val = try b.emitBinOp(.eq, t_i64, t_i64, scrut_val, pat_val);
            const is_last = ai + 1 == arm_list.items.len;
            const next_else = if (is_last) exit_id else try b.newBlock("match_next");
            try b.emitCondBr(cmp_val, arm_block, next_else);
            b.blk = arm_block;
            if (arm.action_is_block) {
                try lowerBodyStr(b, arm.action, ';');
            } else {
                try lowerStmt(b, arm.action);
            }
            if (!b.terminated()) try b.emitBr(exit_id);
            if (!is_last) b.blk = next_else;
        }
        b.blk = exit_id;
    }
}

pub fn lowerProgram(allocator: Allocator, program: *const ast.ProgramNode) !bir.Module {
    var module = bir.Module.init(allocator);
    errdefer module.deinit();

    try ensureTypes(&module);
    try buildStructRegistry(allocator, &module, program);
    try buildEnumRegistry(allocator, program);

    var func_sig_map = std.StringHashMap(TypeId).init(allocator);
    defer func_sig_map.deinit();
    for (program.metal.func_defs.items) |func| {
        const ret_type = if (func.return_type) |rt| try mapType(&module, rt) else inferReturnType(&module, func);
        try func_sig_map.put(func.name, ret_type);
    }

    for (program.metal.extern_cpp_fns.items) |ext| {
        const ret_type = if (ext.return_type) |rt| try mapType(&module, rt) else t_void;
        try func_sig_map.put(ext.name, ret_type);
    }

    if (!g_func_param_ready) {
        g_func_param_types = std.StringHashMap(std.ArrayList(TypeId)).init(allocator);
        g_func_param_ready = true;
        for (program.metal.func_defs.items) |cand| {
            var plist = std.ArrayList(TypeId).init(allocator);
            for (cand.params.items) |p| {
                try plist.append(try mapType(&module, p.type_name));
            }
            try g_func_param_types.put(cand.name, plist);
        }
        for (program.metal.extern_cpp_fns.items) |ext| {
            var plist = std.ArrayList(TypeId).init(allocator);
            for (ext.parameters.items) |p| {
                try plist.append(try mapType(&module, p.type_name));
            }
            try g_func_param_types.put(ext.name, plist);
        }
    }

    for (program.metal.func_defs.items) |func| {
        try lowerFunction(allocator, &module, func, &func_sig_map);
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

fn buildStructRegistry(allocator: Allocator, module: *bir.Module, program: *const ast.ProgramNode) !void {
    if (g_struct_registry_ready) return;
    g_struct_registry = std.StringHashMap(StructLayout).init(allocator);
    g_struct_registry_ready = true;

    // Pass A: create every struct TypeId so nested references resolve in any order.
    {
        var it = program.metal.struct_defs.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const empty_fields = try allocator.alloc(TypeId, 0);
            const empty_offsets = try allocator.alloc(u32, 0);
            const name_owned = try allocator.dupe(u8, name);
            const tid = try module.types.add(.{ .struct_type = .{
                .name = name_owned,
                .fields = empty_fields,
                .offsets = empty_offsets,
                .size_val = 0,
                .alignment_val = 8,
            } });
            try g_struct_registry.put(name, .{ .type_id = tid, .fields = std.StringHashMap(FieldInfo).init(allocator) });
        }
    }

    // Pass B: compute 8-aligned layouts (struct fields sized by their own struct size).
    var sizes = std.StringHashMap(u32).init(allocator);
    defer sizes.deinit();

    var it = program.metal.struct_defs.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const def = entry.value_ptr;
        if (!sizes.contains(name)) {
            const total = structTotalSize(def, &program.metal.struct_defs, &sizes);
            try sizes.put(name, total);
        }
    }

    it = program.metal.struct_defs.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const def = entry.value_ptr;
        const tid = g_struct_registry.get(name).?.type_id;
        const layout = g_struct_registry.getPtr(name).?;

        const n = def.fields.items.len;
        const fields_arr = try allocator.alloc(TypeId, n);
        const offsets_arr = try allocator.alloc(u32, n);
        const name_owned = try allocator.dupe(u8, name);

        var cursor: u32 = 0;
        for (def.fields.items, 0..) |f, i| {
            const raw_ty = try mapType(module, f.type_name);
            const fty = normalizedAggregateType(module, raw_ty);
            fields_arr[i] = fty;
            offsets_arr[i] = cursor;
            try layout.fields.put(f.name, .{ .type_id = fty, .offset = cursor });
            var field_sz: u32 = 8;
            if (sizes.get(f.type_name)) |sz| field_sz = @max(8, sz);
            cursor += field_sz;
        }

        module.types.types.items[tid].kind = .{ .struct_type = .{
            .name = name_owned,
            .fields = fields_arr,
            .offsets = offsets_arr,
            .size_val = cursor,
            .alignment_val = 8,
        } };
    }
}

fn structTotalSize(
    def: *const ast.StructDef,
    defs: *const std.StringHashMap(ast.StructDef),
    sizes: *std.StringHashMap(u32),
) u32 {
    var total: u32 = 0;
    for (def.fields.items) |f| {
        if (defs.get(f.type_name)) |nested_def| {
            if (sizes.get(nested_def.name)) |nsz| {
                total += nsz;
            } else {
                const nsz = structTotalSize(&nested_def, defs, sizes);
                total += nsz;
            }
        } else {
            total += 8;
        }
    }
    sizes.put(def.name, total) catch {};
    return total;
}

const VarInfo = struct {
    value: ValueId,
    type_id: TypeId,
    is_param: bool = false,
};

fn inferReturnType(module: *bir.Module, func: ast.EntryDecl) TypeId {
    _ = module;
    for (func.body_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "return")) continue;
        const rest = std.mem.trim(u8, trimmed["return".len..], " \t\r\n");
        if (rest.len == 0) continue;
        if (rest[0] == '"') return t_ptr;
        if (std.mem.eql(u8, rest, "true") or std.mem.eql(u8, rest, "false")) return t_i1;
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
        return t_i64;
    }
    return t_void;
}

fn lowerFunction(
    allocator: Allocator,
    module: *bir.Module,
    func: ast.EntryDecl,
    func_sig_map: *const std.StringHashMap(TypeId),
) !void {
    try ensureTypes(module);
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
        .ptr_map = std.StringHashMap(PtrInfo).init(allocator),
        .const_vals = std.StringHashMap(i64).init(allocator),
    .const_vars = std.StringHashMap(void).init(allocator),
    };
    var sig_it = func_sig_map.iterator();
    while (sig_it.next()) |entry| {
        try b.func_return_types.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    defer b.vars.deinit();
    defer b.func_return_types.deinit();
    defer b.loop_stack.deinit();
    defer b.ptr_map.deinit();
defer b.const_vals.deinit();
    defer b.const_vars.deinit();

    b.declared_ret = func.return_type != null;

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
.ptr_map = std.StringHashMap(PtrInfo).init(allocator),
    .const_vals = std.StringHashMap(i64).init(allocator),
    .const_vars = std.StringHashMap(void).init(allocator),
    .declared_ret = false,
    };
    defer ab.vars.deinit();
                defer ab.func_return_types.deinit();
                defer ab.loop_stack.deinit();
                defer ab.ptr_map.deinit();
    defer ab.const_vals.deinit();
    defer ab.const_vars.deinit();
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
        .ptr_map = std.StringHashMap(PtrInfo).init(allocator),
    .const_vals = std.StringHashMap(i64).init(allocator),
    .const_vars = std.StringHashMap(void).init(allocator),
    .declared_ret = false,
    };
    defer b.vars.deinit();
    defer b.func_return_types.deinit();
    defer b.loop_stack.deinit();
    defer b.ptr_map.deinit();
    defer b.const_vals.deinit();
    defer b.const_vars.deinit();

    for (state.variables.items) |v| {
        const resolved_type = v.type_name orelse blk: {
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
        .ptr_map = std.StringHashMap(PtrInfo).init(allocator),
    .const_vals = std.StringHashMap(i64).init(allocator),
    .const_vars = std.StringHashMap(void).init(allocator),
    .declared_ret = false,
    };
    defer b.vars.deinit();
    defer b.func_return_types.deinit();
    defer b.loop_stack.deinit();
    defer b.ptr_map.deinit();
    defer b.const_vals.deinit();
    defer b.const_vars.deinit();
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
    ptr_map: std.StringHashMap(PtrInfo),
    const_vals: std.StringHashMap(i64),
    const_vars: std.StringHashMap(void),
    declared_ret: bool = false,

    fn terminated(self: *Builder) bool {
        const bl = self.mod.getFunctionMut(self.fid).getBlock(self.blk);
        if (bl.instrs.items.len == 0) return false;
        const last = bl.instrs.items[bl.instrs.items.len - 1];
        return last.op == .ret or last.op == .br or last.op == .cond_br;
    }

    fn retTypeName(self: *Builder) []const u8 {
        if (self.ret_type == t_i8) return "i8";
        if (self.ret_type == t_i16) return "i16";
        if (self.ret_type == t_i32) return "i32";
        if (self.ret_type == t_i64) return "i64";
        if (self.ret_type == t_u8) return "u8";
        if (self.ret_type == t_u16) return "u16";
        if (self.ret_type == t_u32) return "u32";
        if (self.ret_type == t_u64) return "u64";
        if (self.ret_type == t_f32) return "f32";
        if (self.ret_type == t_f64) return "f64";
        if (self.ret_type == t_ptr) return "string";
        return "unknown";
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
        if (ty == t_f32 or ty == t_f64) {
            std.log.err("type mismatch: unary negation is not supported for float types", .{});
            return BIRError.TypeError;
        }
        const zero = try self.emitConstInt(0);
        return self.emitBinOp(.sub, ty, ty, zero, val);
    }

    fn emitNot(self: *Builder, val: ValueId) !ValueId {
        return self.emitOp(.not, t_i1, &.{val}, .{ .none = {} });
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
    if (std.mem.eql(u8, op_str, "&")) {
        if (is_int or is_bool) return .and_op;
    }
    if (std.mem.eql(u8, op_str, "|")) {
        if (is_int or is_bool) return .or_op;
    }
    if (std.mem.eql(u8, op_str, "^")) {
        if (is_int or is_bool) return .xor_op;
    }
    if (std.mem.eql(u8, op_str, "<<")) {
        if (is_int) return .shl;
    }
    if (std.mem.eql(u8, op_str, ">>")) {
        if (is_int) return .shr;
    }
    std.log.err("type mismatch: operator '{s}' is not valid for this type", .{op_str});
    return BIRError.TypeError;
}

fn inferExprType(b: *Builder, expr: []const u8) !TypeId {
    const t = std.mem.trim(u8, expr, " \t\r\n");
    if (t.len == 0) return t_void;

    if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false")) return t_i1;

    if (t[0] == '"') return t_ptr;

    if (t[0] == '\'' and t.len >= 3 and t[t.len - 1] == '\'') return t_i64;

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

    if (t[0] == '-' and t.len > 1) return try inferExprType(b, t[1..]);

    if (t[0] == '!' and t.len > 1) {
        const rest = t[1..];
        return try inferExprType(b, rest);
    }

    if (t[0] == '&' and t.len > 1) return t_ptr;

    if (isPureAccessText(t) and (t[0] == '*' or lookLikeDotted(t))) {
        return try inferAccessType(b, t);
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
            const lf = lty == t_f32 or lty == t_f64;
            const rf = rty == t_f32 or rty == t_f64;
            if (lf or rf) return if (lf) lty else rty;
            std.log.err("type mismatch: incompatible types in binary operation (different types must match in B+)", .{});
            return BIRError.TypeError;
        }
    }

    if (t.len > 2 and t[0] == '{' and t[t.len - 1] == '}') {
        if (structNameLiteral(b, t)) |sname| {
            return g_struct_registry.get(sname).?.type_id;
        }
        var elems = try splitTopLevel(b.alloc, t[1 .. t.len - 1], ",;");
        defer elems.deinit();
        if (elems.items.len == 0) return t_void;
        var elem_ty: TypeId = t_i64;
        var has_float = false;
        var has_str = false;
        for (elems.items) |e| {
            const tr = std.mem.trim(u8, e, " \t\r\n");
            if (tr.len == 0) continue;
            if (tr[0] == '"') {
                has_str = true;
                continue;
            }
            const et = try inferExprType(b, tr);
            if (et == t_f64 or et == t_f32) has_float = true;
        }
        if (has_str) elem_ty = t_ptr else if (has_float) elem_ty = t_f64;
        return try makeArrayType(b, elem_ty, elems.items.len);
    }

    if (b.getVar(t)) |vi| return vi.type_id;

    return t_i64;
}

fn isPureAccessText(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    var i: usize = 0;
    while (i < t.len and t[i] == '*') i += 1;
    var j = i;
    while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '_')) j += 1;
    if (j == i) return false;
    var consumed = j;
    while (consumed < t.len and t[consumed] == '.') {
        j = consumed + 1;
        while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '_' or t[j] == '-')) j += 1;
        if (j == consumed + 1) return false;
        consumed = j;
    }
    return consumed == t.len;
}

fn isAccessPath(lhs: []const u8) bool {
    const t = std.mem.trim(u8, lhs, " \t\r\n");
    if (t.len == 0) return false;
    if (t[0] == '*') return true;
    return isPureAccessText(t) and lookLikeDotted(t);
}

fn emitAddConst(b: *Builder, base: ValueId, off: i64) !ValueId {
    if (off == 0) return base;
    const c = try b.emitConstInt(off);
    return b.emitOp(.add, t_i64, &.{ base, c }, .{ .none = {} });
}

fn derefChain(b: *Builder, base_name: []const u8, cur: ValueId, depth: usize) anyerror!LValue {
    var target = cur;
    var info = b.ptr_map.get(base_name);
    var i: usize = 0;
    while (i + 1 < depth) : (i += 1) {
        target = try b.emitLoad(target, t_ptr);
        if (info) |inf| {
            if (inf.inner) |inn| {
                info = b.ptr_map.get(inn);
            } else info = null;
        }
    }
    const leaf = if (info) |inf| inf.access_ty else t_i64;
    return .{ .addr = target, .ty = leaf };
}

fn resolveAccess(b: *Builder, text: []const u8) anyerror!?LValue {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    if (t[0] == '(' or t[0] == '{') return null;

    var star_count: usize = 0;
    while (star_count < t.len and t[star_count] == '*') : (star_count += 1) {}
    if (star_count > 0) {
        if (star_count == t.len) return BIRError.UnknownExpression;
        const base = std.mem.trim(u8, t[star_count..], " \t\r\n");
        const base_vi = b.getVar(base) orelse {
            std.log.err("error: unknown variable '{s}' in BIR lowering", .{base});
            return BIRError.UnknownExpression;
        };
        const base_addr = if (base_vi.is_param) base_vi.value else try b.emitLoad(base_vi.value, t_ptr);
        const der = try derefChain(b, base, base_addr, star_count);
        return der;
    }

    const t_trim_end = std.mem.indexOfAny(u8, t, ". ") orelse t.len;
    const base = std.mem.trim(u8, t[0..t_trim_end], " \t\r\n");
    const base_vi = b.getVar(base) orelse return null;

    var addr_val = base_vi.value;
    var cur_ty = base_vi.type_id;
    if (t_trim_end == t.len) {
        return .{ .addr = addr_val, .ty = cur_ty };
    }

    var pos = t_trim_end;
    var cur_layout: ?*const StructLayout = if (cur_ty != bir_types.INVALID_TYPE) lookupStructByType(b, cur_ty) else null;

    while (pos < t.len) {
        if (t[pos] == ' ') pos += 1;
        if (pos >= t.len or t[pos] != '.') break;
        var end = pos + 1;
        while (end < t.len and (std.ascii.isAlphanumeric(t[end]) or t[end] == '_' or t[end] == '-')) : (end += 1) {}
        const part = std.mem.trim(u8, t[pos + 1 .. end], " \t\r\n");
        if (part.len == 0) return BIRError.UnknownExpression;
        pos = end;

        if (isArrayType(b.mod, cur_ty)) {
            var off_val: ValueId = undefined;
            if (isSignedInt(part)) {
                const idx = std.fmt.parseInt(i64, part, 10) catch -1;
                const arr_kind = b.mod.types.get(cur_ty).kind.array;
                if (idx < 0) {
                    std.log.err("error: array index is out of bounds", .{});
                    return BIRError.UnknownExpression;
                }
                if (idx >= @as(i64, @intCast(arr_kind.len))) {
                    std.log.err("error: array index is out of bounds", .{});
                    return BIRError.UnknownExpression;
                }
                off_val = try b.emitConstInt(idx * 8);
            } else {
                const idx_vi = b.getVar(part) orelse {
                    std.log.err("error: unknown variable '{s}' in BIR lowering", .{part});
                    return BIRError.UnknownExpression;
                };
                const idx_val = if (idx_vi.is_param) idx_vi.value else try b.emitLoad(idx_vi.value, idx_vi.type_id);
                const eight = try b.emitConstInt(8);
                off_val = try b.emitOp(.mul, t_i64, &.{ idx_val, eight }, .{ .none = {} });
            }
            addr_val = try b.emitOp(.add, t_i64, &.{ addr_val, off_val }, .{ .none = {} });
            cur_ty = b.mod.types.get(cur_ty).kind.array.elem;
            cur_layout = null;
            continue;
        }

        if (cur_layout) |lay| {
            const fi = lay.fields.get(part) orelse {
                std.log.err("error: unknown struct field '{s}'", .{part});
                return BIRError.UnknownExpression;
            };
            addr_val = try emitAddConst(b, addr_val, @as(i64, fi.offset));
            cur_ty = fi.type_id;
            cur_layout = if (cur_ty == bir_types.INVALID_TYPE) null else lookupStructByType(b, cur_ty);
            continue;
        }

        if (lookupStructByField(b, part)) |lay2| {
            const fi = lay2.fields.get(part).?;
            addr_val = try emitAddConst(b, addr_val, @as(i64, fi.offset));
            cur_ty = fi.type_id;
            cur_layout = lookupStructByType(b, cur_ty);
            continue;
        }

        std.log.err("error: unknown struct field '{s}'", .{part});
        return BIRError.UnknownExpression;
    }

    return .{ .addr = addr_val, .ty = cur_ty };
}

fn inferAccessType(b: *Builder, text: []const u8) anyerror!TypeId {
    const t = std.mem.trim(u8, text, " \t\r\n");

    var star_count: usize = 0;
    while (star_count < t.len and t[star_count] == '*') : (star_count += 1) {}
    if (star_count > 0) {
        if (star_count == t.len) return t_i64;
        const base = std.mem.trim(u8, t[star_count..], " \t\r\n");
        var info = b.ptr_map.get(base);
        if (info == null) return t_i64;
        var leaf = info.?.access_ty;
        var i: usize = 0;
        while (i + 1 < star_count) : (i += 1) {
            if (info) |inf| {
                if (inf.inner) |inn| {
                    info = b.ptr_map.get(inn);
                } else info = null;
            }
            leaf = if (info) |inf| inf.access_ty else t_i64;
        }
        return leaf;
    }

    const t_trim_end = std.mem.indexOfAny(u8, t, ". ") orelse return t_i64;
    const base = std.mem.trim(u8, t[0..t_trim_end], " \t\r\n");
    const base_vi = b.getVar(base) orelse return t_i64;
    var cur_ty = base_vi.type_id;
    var pos = t_trim_end;
    while (pos < t.len) {
        if (t[pos] == ' ') pos += 1;
        if (pos >= t.len or t[pos] != '.') break;
        var end = pos + 1;
        while (end < t.len and (std.ascii.isAlphanumeric(t[end]) or t[end] == '_' or t[end] == '-')) : (end += 1) {}
        const part = std.mem.trim(u8, t[pos + 1 .. end], " \t\r\n");
        if (part.len == 0) return t_i64;
        pos = end;

        if (isArrayType(b.mod, cur_ty)) {
            cur_ty = b.mod.types.get(cur_ty).kind.array.elem;
            continue;
        }
        if (lookupStructByType(b, cur_ty)) |l2| {
            if (l2.fields.get(part)) |fi| {
                cur_ty = fi.type_id;
                continue;
            }
            return t_i64;
        }
        if (lookupStructByField(b, part)) |l3| {
            if (l3.fields.get(part)) |fi| {
                cur_ty = fi.type_id;
                continue;
            }
            return t_i64;
        }
        return t_i64;
    }
    return cur_ty;
}

fn makeArrayType(b: *Builder, elem_ty: TypeId, len: usize) !TypeId {
    return b.mod.types.arrayType(elem_ty, @intCast(len));
}

fn lowerArrayElemStores(b: *Builder, slot: ValueId, rhs: []const u8) anyerror!void {
    const t = std.mem.trim(u8, rhs, " \t\r\n");
    if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return BIRError.UnknownExpression;
    var elems = try splitTopLevel(b.alloc, t[1 .. t.len - 1], ",;");
    defer elems.deinit();

    const elem_ty = try arrayLiteralElemType(b, elems.items);
    for (elems.items, 0..) |e, i| {
        const tr = std.mem.trim(u8, e, " \t\r\n");
        if (tr.len == 0) continue;
        const val = try lowerExpr(b, tr);
        const off = try b.emitConstInt(@as(i64, @intCast(i)) * 8);
        const addr = try b.emitOp(.add, t_i64, &.{ slot, off }, .{ .none = {} });
        try b.emitStore(elem_ty, addr, val);
    }
}

fn arrayLiteralElemType(b: *Builder, elems: []const []const u8) anyerror!TypeId {
    var elem_ty: TypeId = t_i64;
    var has_float = false;
    var has_str = false;
    for (elems) |e| {
        const tr = std.mem.trim(u8, e, " \t\r\n");
        if (tr.len == 0) continue;
        if (tr[0] == '"') {
            has_str = true;
            continue;
        }
        const et = try inferExprType(b, tr);
        if (et == t_f64 or et == t_f32) has_float = true;
    }
    if (has_str) elem_ty = t_ptr else if (has_float) elem_ty = t_f64;
    return elem_ty;
}

fn lowerArrayLiteral(b: *Builder, text: []const u8) anyerror!ValueId {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return BIRError.UnknownExpression;
    var elems = try splitTopLevel(b.alloc, t[1 .. t.len - 1], ",;");
    defer elems.deinit();
    if (elems.items.len == 0) return BIRError.UnknownExpression;

    const elem_ty = try arrayLiteralElemType(b, elems.items);
    const aty = try makeArrayType(b, elem_ty, elems.items.len);
    const slot = try b.emitAlloca(aty);
    for (elems.items, 0..) |e, i| {
        const tr = std.mem.trim(u8, e, " \t\r\n");
        if (tr.len == 0) continue;
        const val = try lowerExpr(b, tr);
        const off = try b.emitConstInt(@as(i64, @intCast(i)) * 8);
        const addr = try b.emitOp(.add, t_i64, &.{ slot, off }, .{ .none = {} });
        try b.emitStore(elem_ty, addr, val);
    }
    return slot;
}

fn lowerAggregateInit(b: *Builder, name: []const u8, rhs: []const u8) anyerror!bool {
    const t = std.mem.trim(u8, rhs, " \t\r\n");
    if (structNameLiteral(b, t)) |sname| {
        const lay = g_struct_registry.get(sname).?;
        if (b.getVar(name) == null) {
            const slot = try b.emitAlloca(lay.type_id);
            try b.vars.put(name, .{ .value = slot, .type_id = lay.type_id });
            {
                const fn_mut = b.mod.getFunctionMut(b.fid);
                const owned_name = try b.alloc.dupe(u8, name);
                try fn_mut.value_debug_names.put(slot, owned_name);
            }
        }
        return true;
    }
    if (t.len > 1 and t[0] == '{' and t[t.len - 1] == '}') {
        const aty = try inferExprType(b, t);
        if (b.getVar(name) == null) {
            const slot = try b.emitAlloca(aty);
            try b.vars.put(name, .{ .value = slot, .type_id = aty });
            {
                const fn_mut = b.mod.getFunctionMut(b.fid);
                const owned_name = try b.alloc.dupe(u8, name);
                try fn_mut.value_debug_names.put(slot, owned_name);
            }
        }
        const slot = b.getVar(name).?.value;
        try lowerArrayElemStores(b, slot, t);
        return true;
    }
    return false;
}

fn lowerStmt(b: *Builder, line: []const u8) anyerror!void {
    if (b.terminated()) return;

    if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "const ")) {
        const rest = std.mem.trimLeft(u8, line, " \t")["const ".len..];
        const cname = extractName(rest);
        if (cname.len > 0) try b.const_vars.put(cname, {});
        try lowerStmt(b, rest);
        return;
    }

    if (std.mem.startsWith(u8, line, "return")) {
        const rest = std.mem.trim(u8, line["return".len..], " \t\r\n");
        if (rest.len == 0) {
            try b.retVoid();
        } else {
            const val = try lowerExpr(b, rest);
            const ty = try inferExprType(b, rest);
            if (b.declared_ret and b.ret_type != t_void and ty != t_void and b.ret_type != ty) {
                const ok = (ty == t_i64 and isNumericOrFloat(b.mod, b.ret_type)) or
                    (isFloatType(b.mod, b.ret_type) and isNumericOrFloat(b.mod, ty));
                if (!ok) {
                    std.log.err("type mismatch: function must return '{s}' but returned a different type", .{b.retTypeName()});
                    return BIRError.TypeError;
                }
            }
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
        } else if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
            const expr_str = std.mem.trim(u8, rest[eq + 1 ..], " \t\r\n");
            if (try lowerAggregateInit(b, name, expr_str)) return;
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

    if (std.mem.startsWith(u8, line, "match ")) {
        try lowerMatch(b, line[6..]);
        return;
    }

    const compound_ops = [_][]const u8{ "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=" };
    for (compound_ops) |cop| {
        if (std.mem.indexOf(u8, line, cop)) |idx| {
            if (idx == 0) continue;
            const lhs = std.mem.trim(u8, line[0..idx], " \t\r\n");
            const rhs = std.mem.trim(u8, line[idx + 2 ..], " \t\r\n");
            if (lhs.len == 0 or rhs.len == 0) break;
            if (b.const_vars.contains(lhs)) {
                std.log.err("error: cannot modify const variable '{s}'", .{lhs});
                return BIRError.TypeError;
            }
            var lv: ?LValue = null;
            if (isAccessPath(lhs)) {
                lv = try resolveAccess(b, lhs);
            } else if (b.getVar(lhs)) |vi| {
                lv = .{ .addr = vi.value, .ty = vi.type_id };
            }
            if (lv == null) break;
            const lv2 = lv.?;
            if (isAggregate(b.mod, lv2.ty)) {
                std.log.err("error: cannot modify a whole aggregate value", .{});
                return BIRError.TypeError;
            }
            if (intRange(lv2.ty)) |rng| {
                if (constIntOfExpr(b, rhs)) |r_val| {
                    const base = b.const_vals.get(lhs) orelse 0;
                    const op_char = cop[0];
                    const new_val: i64 = switch (op_char) {
                        '+' => base +% r_val,
                        '-' => base -% r_val,
                        '*' => base *% r_val,
                        '/' => if (r_val == 0) {
                            std.log.err("error: division by zero", .{});
                            return BIRError.TypeError;
                        } else @divTrunc(base, r_val),
                        '%' => if (r_val == 0) {
                            std.log.err("error: division by zero", .{});
                            return BIRError.TypeError;
                        } else @rem(base, r_val),
                        else => base,
                    };
                    if (new_val < rng.min or new_val > rng.max) {
                        std.log.err("error: overflow: value {d} does not fit in type", .{new_val});
                        return BIRError.TypeError;
                    }
                    try b.const_vals.put(lhs, new_val);
                }
            }
            const cur = try b.emitLoad(lv2.addr, lv2.ty);
            const rval = try lowerExpr(b, rhs);
            const rty = try inferExprType(b, rhs);
            if (lv2.ty != rty and !(isIntScalarType(b.mod, lv2.ty) and isIntScalarType(b.mod, rty))) {
                std.log.err("type mismatch: incompatible types in compound assignment", .{});
                return BIRError.TypeError;
            }
            const bir_op = try resolveBinOp(cop[0..1], lv2.ty);
            const res = try b.emitOp(bir_op, lv2.ty, &.{ cur, rval }, .{ .none = {} });
            try b.emitStore(lv2.ty, lv2.addr, res);
            return;
        }
    }

    if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
        const lhs = std.mem.trim(u8, line[0..eq_idx], " \t\r\n");
        const rhs = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r\n");
        if (lhs.len > 0 and rhs.len > 0) {
            if (std.mem.indexOfScalar(u8, lhs, ':')) |colon_idx| {
                const var_name = std.mem.trim(u8, lhs[0..colon_idx], " \t\r\n");
                const type_name = std.mem.trim(u8, lhs[colon_idx + 1 ..], " \t\r\n");
                if (var_name.len > 0 and type_name.len > 0) {
                    const var_type = try mapType(b.mod, type_name);
                    if (intRange(var_type)) |rng| {
                        if (constIntOfExpr(b, rhs)) |r_val| {
                            if (r_val < rng.min or r_val > rng.max) {
                                std.log.err("error: value {d} out of range for type '{s}'", .{ r_val, type_name });
                                return BIRError.TypeError;
                            }
                            if (std.mem.indexOfScalar(u8, rhs, '.') == null) try b.const_vals.put(var_name, r_val);
                        }
                    }
                    if (rhs.len > 1 and rhs[0] == '{' and rhs[rhs.len - 1] == '}') {
                        if (structNameLiteral(b, rhs)) |_| {
                            if (!isAggregate(b.mod, var_type)) {
                                std.log.err("type mismatch: cannot assign struct literal to variable '{s}' of type '{s}'", .{ var_name, type_name });
                                return BIRError.TypeError;
                            }
                        } else if (!isArrayType(b.mod, var_type)) {
                            std.log.err("type mismatch: cannot assign array literal to variable '{s}' of type '{s}'", .{ var_name, type_name });
                            return BIRError.TypeError;
                        }
                    }
                    if (try lowerAggregateInit(b, var_name, rhs)) return;
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
                        if (var_type != t_i64 and var_type != store_ty and !checkAssignableToVar(b, var_type, store_ty)) {
                            std.log.err("type mismatch: cannot assign '{s}' to variable of type '{s}'", .{ type_name, type_name });
                            return BIRError.TypeError;
                        }
                        try b.emitStore(store_ty, slot, val);
                    }
                    return;
                }
            }
            if (isAccessPath(lhs)) {
                const lv = (try resolveAccess(b, lhs)) orelse {
                    std.log.err("error: invalid assignment target '{s}'", .{lhs});
                    return BIRError.UnknownExpression;
                };
                if (isAggregate(b.mod, lv.ty)) {
                    std.log.err("error: cannot assign to a whole aggregate '{s}'", .{lhs});
                    return BIRError.TypeError;
                }
                const val = try lowerExpr(b, rhs);
                const rty = try inferExprType(b, rhs);
                const store_ty = if (rty != t_i64) rty else lv.ty;
                if (rty != t_i64 and rty != store_ty and !checkAssignableToVar(b, lv.ty, store_ty)) {
                    std.log.err("type mismatch: incompatible types in assignment", .{});
                    return BIRError.TypeError;
                }
                try b.emitStore(store_ty, lv.addr, val);
                return;
            }
            if (try lowerAggregateInit(b, lhs, rhs)) return;
            if (rhs.len > 1 and rhs[0] == '&') {
                const target = std.mem.trim(u8, rhs[1..], " \t\r\n");
                if (target.len > 0) {
                    const lv = (try resolveAccess(b, target)) orelse {
                        std.log.err("error: cannot take address of '{s}'", .{target});
                        return BIRError.UnknownExpression;
                    };
                    if (b.getVar(lhs) == null) {
                        const slot = try b.emitAlloca(t_ptr);
                        try b.vars.put(lhs, .{ .value = slot, .type_id = t_ptr });
                        {
                            const fn_mut = b.mod.getFunctionMut(b.fid);
                            const owned_name = try b.alloc.dupe(u8, lhs);
                            try fn_mut.value_debug_names.put(slot, owned_name);
                        }
                    }
                    const pslot = b.getVar(lhs).?.value;
                    try b.emitStore(t_ptr, pslot, lv.addr);
                    var inner: ?[]const u8 = null;
                    if (b.getVar(target) != null and b.ptr_map.contains(target)) inner = target;
                    try b.ptr_map.put(try ptrInfoKey(b, lhs), .{ .access_ty = lv.ty, .inner = inner });
                    return;
                }
            }
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
                if (std.mem.indexOfScalar(u8, rhs, '.') == null) {
                    if (constIntOfExpr(b, rhs)) |cv| try b.const_vals.put(lhs, cv);
                }
                if (inferred_type == t_ptr) {
                    const rhs_name = std.mem.trim(u8, rhs, " \t\r\n");
                    if (b.ptr_map.get(rhs_name)) |pin_info| {
                        try b.ptr_map.put(try ptrInfoKey(b, lhs), pin_info);
                    }
                }
                return;
            }
            if (b.getVar(lhs)) |vi| {
                if (b.const_vars.contains(lhs)) {
                    std.log.err("error: cannot assign to const variable '{s}'", .{lhs});
                    return BIRError.TypeError;
                }
                const val = try lowerExpr(b, rhs);
                const expr_ty = try inferExprType(b, rhs);
                const store_ty = if (expr_ty != t_i64) expr_ty else vi.type_id;
                if (store_ty != vi.type_id and store_ty != t_i64 and !checkAssignableToVar(b, vi.type_id, store_ty)) {
                    std.log.err("type mismatch: cannot assign '{s}' to variable of type '{s}'", .{ "rhs", "lhs" });
                    return BIRError.TypeError;
                }
                try b.emitStore(store_ty, vi.value, val);
                if (std.mem.indexOfScalar(u8, rhs, '.') == null) {
                    if (constIntOfExpr(b, rhs)) |cv| try b.const_vals.put(lhs, cv) else _ = b.const_vals.remove(lhs);
                } else {
                    _ = b.const_vals.remove(lhs);
                }
                if (expr_ty == t_ptr) {
                    const rhs_name = std.mem.trim(u8, rhs, " \t\r\n");
                    if (b.ptr_map.get(rhs_name)) |pin_info| {
                        try b.ptr_map.put(try ptrInfoKey(b, lhs), pin_info);
                    }
                }
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

    if (t[0] == '\'' and t.len >= 3 and t[t.len - 1] == '\'') {
        const inner = t[1 .. t.len - 1];
        if (inner.len == 1) {
            return b.emitConstInt(@as(i64, inner[0]));
        } else if (inner.len == 2 and inner[0] == '\\') {
            const ch: u8 = switch (inner[1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '\'' => '\'',
                '0' => 0,
                else => inner[1],
            };
            return b.emitConstInt(@as(i64, ch));
        }
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
            if (std.fmt.parseInt(i64, t, 10)) |iv| {
                return b.emitConstInt(iv);
            } else |_| {
                const uv = std.fmt.parseInt(u64, t, 10) catch return error.NumberNotRepresentable;
                return b.emitConstInt(@bitCast(uv));
            }
        }
    }

    if (t[0] == '(') {
        if (findParenEnd(t, 0)) |end| {
            if (end == t.len - 1) return lowerExpr(b, t[1..end]);
        }
    }

    if (t[0] == '!' and t.len > 1) {
        const rest = t[1..];
        const inner = try lowerExpr(b, rest);
        const ty = try inferExprType(b, rest);
        if (ty != t_i1) {
            if (!isIntScalarType(b.mod, ty)) {
                std.log.err("type mismatch: '!' operator requires bool operand", .{});
                return BIRError.TypeError;
            }
            const zero = try b.emitConstInt(0);
            return b.emitBinOp(.eq, ty, ty, inner, zero);
        }
        return try b.emitNot(inner);
    }

    if (t[0] == '~' and t.len > 1) {
        const rest = t[1..];
        const inner_expr = if (rest[0] == '(') blk: {
            if (findParenEnd(rest, 0)) |pend| {
                if (pend == rest.len - 1) break :blk std.mem.trim(u8, rest[1..pend], " \t\r\n");
            }
            break :blk rest;
        } else rest;
        const inner = try lowerExpr(b, inner_expr);
        const ty = try inferExprType(b, inner_expr);
        const minus_one = try b.emitConstInt(-1);
        return b.emitOp(.xor_op, ty, &.{ inner, minus_one }, .{ .none = {} });
    }

    if (t[0] == '&' and t.len > 1) {
        const target = std.mem.trim(u8, t[1..], " \t\r\n");
        const lv = (try resolveAccess(b, target)) orelse {
            std.log.err("error: cannot take address of '{s}'", .{target});
            return BIRError.UnknownExpression;
        };
        return lv.addr;
    }

    if (t[0] == '{' and t.len > 1) {
        if (structNameLiteral(b, t)) |sname| {
            const lay = g_struct_registry.get(sname).?;
            return b.emitAlloca(lay.type_id);
        }
        return lowerArrayLiteral(b, t);
    }

    if (isPureAccessText(t) and t[0] == '*') {
        const lv = (try resolveAccess(b, t)) orelse {
            std.log.err("error: unrecognized expression '{s}' in BIR lowering", .{t});
            return BIRError.UnknownExpression;
        };
        return if (isAggregate(b.mod, lv.ty)) lv.addr else b.emitLoad(lv.addr, lv.ty);
    }

    if (isPureAccessText(t) and lookLikeDotted(t)) {
        if (std.mem.lastIndexOf(u8, t, ".")) |dot| {
            const enum_name = std.mem.trim(u8, t[0..dot], " \t\r\n");
            const member = std.mem.trim(u8, t[dot + 1 ..], " \t\r\n");
            if (getEnumMember(enum_name, member)) |idx| {
                return b.emitConstInt(idx);
            }
        }
    }

    if (isPureAccessText(t) and lookLikeDotted(t)) {
        if (try resolveAccess(b, t)) |lv| {
            return if (isAggregate(b.mod, lv.ty)) lv.addr else b.emitLoad(lv.addr, lv.ty);
        }
    }

    if (std.mem.indexOfScalar(u8, t, '(')) |pp| {
        if (pp > 0) {
            const nm = std.mem.trim(u8, t[0..pp], " \t\r\n");
            if (isBareName(nm)) {
                if (findParenEnd(t, pp)) |c| {
                    if (c == t.len - 1) return lowerCallExpr(b, nm, std.mem.trim(u8, t[pp + 1 .. c], " \t\r\n"));
                }
            }
        }
    }

    const op_strs = [_][]const u8{ "||", "&&", "==", "!=", "<<", ">>", "<=", ">=", "<", ">", "+", "-", "*", "/", "%", "&", "|", "^" };
    for (op_strs) |op_str| {
        if (findBinOp(t, op_str)) |parts| {
            if ((std.mem.eql(u8, op_str, "/") or std.mem.eql(u8, op_str, "%"))) {
                if (constIntOfExpr(b, parts.right)) |d| {
                    if (d == 0) {
                        std.log.err("error: division by zero", .{});
                        return BIRError.TypeError;
                    }
                }
            }
            const l = try lowerExpr(b, parts.left);
            const r = try lowerExpr(b, parts.right);
            const lty = try inferExprType(b, parts.left);
            const rty = try inferExprType(b, parts.right);
            const lf = lty == t_f32 or lty == t_f64;
            const rf = rty == t_f32 or rty == t_f64;
            if (lty == rty) {
                const bir_op = try resolveBinOp(op_str, lty);
                return b.emitOp(bir_op, lty, &.{ l, r }, .{ .none = {} });
            }
            if (lf or rf) {
                const fty = if (lf) lty else rty;
                const iv = if (lf) r else l;
                const promoted = try b.emitOp(.sitofp, fty, &.{iv}, .{ .none = {} });
                const fop = try resolveBinOp(op_str, fty);
                const lv2 = if (lf) l else promoted;
                const rv2 = if (lf) promoted else r;
                return b.emitOp(fop, fty, &.{ lv2, rv2 }, .{ .none = {} });
            }
            std.log.err("type mismatch: binary operand types must match (got different types)", .{});
            return BIRError.TypeError;
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

fn isBareName(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn lowerCallExpr(b: *Builder, name: []const u8, args_str: []const u8) anyerror!ValueId {
    const callee_name = if (std.mem.eql(u8, name, "print")) blk: {
        const trimmed = std.mem.trim(u8, args_str, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '"') break :blk "print_str";
        const arg_ty = try inferExprType(b, trimmed);
        if (arg_ty == t_f64 or arg_ty == t_f32) break :blk "print_f64";
        if (arg_ty == t_ptr) break :blk "print_str";
        break :blk "print_i64";
    } else name;

    var args = std.ArrayList(ValueId).init(b.alloc);
    defer args.deinit();
    var arg_tys = std.ArrayList(TypeId).init(b.alloc);
    defer arg_tys.deinit();
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
                    if (v != NO_VALUE) {
                        try args.append(v);
                        try arg_tys.append(try inferExprType(b, a));
                    }
                }
                start = i + 1;
            }
        }
        const last = std.mem.trim(u8, args_str[start..], " \t\r\n");
        if (last.len > 0) {
            const v = try lowerExpr(b, last);
            if (v != NO_VALUE) {
                try args.append(v);
                try arg_tys.append(try inferExprType(b, last));
            }
        }
    }
    if (g_func_param_ready) {
        if (g_func_param_types.get(name)) |plist| {
            const expected = plist.items.len;
            const actual = args.items.len;
            if (actual != expected) {
                std.log.err("error: function '{s}' expects {d} argument(s) but got {d}", .{ name, expected, actual });
                return BIRError.TypeError;
            }
            for (args.items, 0..) |_, ai| {
                if (ai >= expected) break;
                const pty = plist.items[ai];
                const aty = arg_tys.items[ai];
                if (pty == aty) continue;
                const p_int = isIntScalarType(b.mod, pty);
                const a_int = isIntScalarType(b.mod, aty);
                const p_float = isFloatType(b.mod, pty);
                const ok = (pty == aty) or
                    isAggregate(b.mod, aty) or
                    (aty == t_i64 and (p_int or p_float)) or
                    (aty == t_ptr and p_int) or
                    (p_int and a_int);
                if (!ok) {
                    std.log.err("type mismatch: function '{s}' argument {d}: expected '{s}' but got a different type", .{ name, ai + 1, plistTypeName(pty) });
                    return BIRError.TypeError;
                }
            }
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

    b.blk = then_id;
    try lowerBodyStr(b, body_str, ';');
    const then_term = b.terminated();

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
        b.blk = else_id;
    } else if (then_term and !else_term) {
        const merge_id = try b.newBlock("if_merge");
        try b.emitBr(merge_id);
        b.blk = merge_id;
    } else if (!then_term and else_term) {
        const merge_id = try b.newBlock("if_merge");
        b.blk = then_id;
        try b.emitBr(merge_id);
        b.blk = merge_id;
    } else {
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

    try b.loop_stack.append(.{ .header_id = header_id, .exit_id = exit_id });
    defer _ = b.loop_stack.pop();

    b.blk = body_id;
    try lowerBodyStr(b, body_str, ';');
    if (!b.terminated()) try b.emitBr(header_id);

    b.blk = exit_id;
}

fn lowerFor(b: *Builder, line: []const u8) anyerror!void {
    const rest = std.mem.trim(u8, line[4..], " \t\r\n");
    const cb = findBraceBlock(rest) orelse return;
    const header_str = std.mem.trim(u8, rest[0..cb.body_start - 1], " \t\r\n");
    const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

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

    if (init_str.len > 0) try lowerStmt(b, init_str);

    const header_id = try b.newBlock("for_header");
    const body_id = try b.newBlock("for_body");
    const update_id = try b.newBlock("for_update");
    const exit_id = try b.newBlock("for_exit");

    try b.emitBr(header_id);

    b.blk = header_id;
    if (cond_str.len > 0) {
        const cond_val = try lowerExpr(b, cond_str);
        if (cond_val == NO_VALUE) return;
        try b.emitCondBr(cond_val, body_id, exit_id);
    } else {
        try b.emitBr(body_id);
    }

    try b.loop_stack.append(.{ .header_id = update_id, .exit_id = exit_id });
    defer _ = b.loop_stack.pop();

    b.blk = body_id;
    try lowerBodyStr(b, body_str, ';');
    if (!b.terminated()) try b.emitBr(update_id);

    b.blk = update_id;
    if (update_str.len > 0) try lowerStmt(b, update_str);
    if (!b.terminated()) try b.emitBr(header_id);

    b.blk = exit_id;
}

fn lowerBreak(b: *Builder) anyerror!void {
    if (b.loop_stack.items.len == 0) {
        std.log.err("error: break statement outside of a loop", .{});
        return BIRError.TypeError;
    }
    const ctx = b.loop_stack.items[b.loop_stack.items.len - 1];
    try b.emitBr(ctx.exit_id);
}

fn lowerContinue(b: *Builder) anyerror!void {
    if (b.loop_stack.items.len == 0) {
        std.log.err("error: continue statement outside of a loop", .{});
        return BIRError.TypeError;
    }
    const ctx = b.loop_stack.items[b.loop_stack.items.len - 1];
    try b.emitBr(ctx.header_id);
}

fn isContinuationChar(c: u8) bool {
    return c == '=' or c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '&' or c == '|' or c == '^' or c == '<' or c == '>';
}

fn mergeContinuations(alloc: Allocator, body: []const u8, sep: u8) ![]u8 {
    var merged = std.ArrayList(u8).init(alloc);
    var depth: i32 = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '"') in_str = !in_str;
        if (in_str or (c != sep and c != '{' and c != '}' and c != '(' and c != ')')) {
            try merged.append(c);
            i += 1;
            continue;
        }
        if (c == '(' or c == '{') depth += 1;
        if (c == ')' or c == '}') depth -= 1;
        if (c == sep and depth == 0) {
            var prev = i;
            while (prev > 0 and (body[prev - 1] == ' ' or body[prev - 1] == '\t' or body[prev - 1] == '\r' or body[prev - 1] == '\n' or body[prev - 1] == sep)) : (prev -= 1) {}
            var next = i + 1;
            while (next < body.len and (body[next] == ' ' or body[next] == '\t' or body[next] == '\r' or body[next] == '\n')) : (next += 1) {}
            const prev_is_op = prev > 0 and isContinuationChar(body[prev - 1]);
            const next_is_op = next < body.len and isContinuationChar(body[next]);
            var next_is_stmt = false;
            if (next_is_op and (body[next] == '*' or body[next] == '&')) {
                var k = next + 1;
                while (k < body.len and body[k] != sep) : (k += 1) {
                    if (body[k] == '=') {
                        next_is_stmt = true;
                        break;
                    }
                }
            }
            if (prev_is_op or (next_is_op and !next_is_stmt)) {
                try merged.append(' ');
            } else {
                try merged.append(sep);
            }
            i += 1;
            continue;
        }
        try merged.append(c);
        i += 1;
    }
    return merged.items;
}

fn lowerBodyStr(b: *Builder, body_input: []const u8, sep: u8) anyerror!void {
    const body = try mergeContinuations(b.alloc, body_input, sep);
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
                const is_ctrl = stmt.len > 2 and (std.mem.startsWith(u8, stmt, "for ") or std.mem.startsWith(u8, stmt, "for(") or std.mem.startsWith(u8, stmt, "while ") or std.mem.startsWith(u8, stmt, "while(") or std.mem.startsWith(u8, stmt, "if ") or std.mem.startsWith(u8, stmt, "if(") or std.mem.startsWith(u8, stmt, "match ") or std.mem.startsWith(u8, stmt, "match("));
                if (is_ctrl) {
                    const glue: u8 = if (std.mem.startsWith(u8, stmt, "for ") or std.mem.startsWith(u8, stmt, "for(")) ';' else ' ';
                    var brace_depth: i32 = 0;
                    for (stmt) |ch| { if (ch == '{') brace_depth += 1; if (ch == '}') brace_depth -= 1; }
                    var found_open = std.mem.indexOfScalar(u8, stmt, '{') != null;
                    var pending_body: bool = false;
                    while (pos < body.len) {
                        if (found_open and brace_depth <= 0 and !pending_body) {
                            var ahead = pos;
                            while (ahead < body.len and (body[ahead] == ' ' or body[ahead] == '\t' or body[ahead] == '\r' or body[ahead] == '\n' or body[ahead] == sep)) : (ahead += 1) {}
                            const is_else = ahead + 4 <= body.len and std.mem.eql(u8, body[ahead .. ahead + 4], "else");
                            if (!is_else) break;
                        }
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
                        if (part.len > 0) {
                            stmt = std.mem.concat(b.alloc, u8, &.{ stmt, &.{glue}, part }) catch stmt;
                            pending_body = std.mem.startsWith(u8, part, "else");
                        }
                        if (!found_open) found_open = std.mem.indexOfScalar(u8, stmt, '{') != null;
                        if (pos < body.len and body[pos] == sep) { pos += 1; }
                    }
                }
                if (stmt.len > 0) try lowerStmt(b, stmt);
                start = pos;
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
        if (std.mem.eql(u8, op, "<") and i + 1 < expr.len and (expr[i + 1] == '=' or expr[i + 1] == '<')) continue;
        if (std.mem.eql(u8, op, ">") and i + 1 < expr.len and (expr[i + 1] == '=' or expr[i + 1] == '>')) continue;
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
