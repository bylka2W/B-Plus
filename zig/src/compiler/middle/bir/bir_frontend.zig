const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const gpu_ir = @import("../../gpu/gpu_ir.zig");
const gpu_ast = @import("../../gpu/frontend/gpu_ast.zig");
const gpu_body_parser = @import("../../gpu/frontend/gpu_body_parser.zig");
const types_mod = @import("bir_types.zig");
const TypeId = types_mod.TypeId;

const Op = bir.Op;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;

pub fn lowerToBir(allocator: Allocator, module: *const gpu_ast.GpuModule) !bir.Module {
    var bir_mod = bir.Module.init(allocator);
    errdefer bir_mod.deinit();

    var type_map = try buildTypeMap(allocator, &bir_mod);
    defer type_map.deinit();

    for (module.kernels.items) |*kernel| {
        var ir_resources = std.ArrayList(gpu_ir.IrResourceDecl).init(allocator);
        defer ir_resources.deinit();

        for (kernel.resources.items) |res| {
            const ir_res = gpuResourceToIr(&res);
            try ir_resources.append(.{
                .name = res.name,
                .type_ref = ir_res.@"0",
                .binding_prefix = ir_res.@"1",
                .binding_reg = res.binding.reg,
                .format = gpuResourceFormatToIr(&res),
            });

            const bir_ty = type_map.get(ir_res.@"0") orelse return error.TypeNotMapped;
            try bir_mod.resources.append(.{
                .name = try allocator.dupe(u8, res.name),
                .ty = bir_ty,
                .binding = res.binding.reg,
                .space = res.binding.space,
            });
        }

        var ir_cbuffer = std.ArrayList(gpu_ir.IrCbufferMember).init(allocator);
        defer ir_cbuffer.deinit();
        for (kernel.cbuffer_members.items) |member| {
            try ir_cbuffer.append(.{
                .name = member.name,
                .type_ref = gpu_ir.scalarTypeToTypeRefWithWidth(member.scalar_type, member.vector_width),
                .slot = member.slot.reg,
            });
        }

        for (kernel.entries.items) |entry| {
            var func_types = extractFuncTypes(allocator, kernel.globals_lines.items);
            defer func_types.deinit();

            var filtered_body = std.ArrayList([]const u8).init(allocator);
            defer filtered_body.deinit();
            for (entry.body_lines.items) |line| {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "numthreads")) {
                    try filtered_body.append(trimmed);
                }
            }

            const ir_func = try gpu_body_parser.parseBody(
                allocator,
                filtered_body.items,
                ir_resources.items,
                ir_cbuffer.items,
                func_types,
            );
            errdefer cleanupIrFunc(allocator, &ir_func);

            const void_ty = type_map.get(.void) orelse return error.TypeNotRegistered;
            const func_id = try bir_mod.addFunction(entry.name, void_ty, .compute);

            bir_mod.getFunctionMut(func_id).numthreads = .{
                .x = entry.numthreads.x,
                .y = entry.numthreads.y,
                .z = entry.numthreads.z,
            };

            try convertIrFunction(allocator, &bir_mod, func_id, &ir_func, &type_map);

            cleanupIrFunc(allocator, &ir_func);
        }
    }

    return bir_mod;
}

fn buildTypeMap(allocator: Allocator, bir_mod: *bir.Module) !std.AutoHashMap(gpu_ir.TypeRef, TypeId) {
    var map = std.AutoHashMap(gpu_ir.TypeRef, TypeId).init(allocator);
    errdefer map.deinit();

    try map.put(.void, try bir_mod.types.voidType());
    try map.put(.f32, try bir_mod.types.scalarType(.f32));
    try map.put(.i32, try bir_mod.types.scalarType(.i32));
    try map.put(.u32, try bir_mod.types.scalarType(.u32));
    try map.put(.f16, try bir_mod.types.scalarType(.f16));
    try map.put(.vec2f, try bir_mod.types.vectorType(.f32, 2));
    try map.put(.vec3f, try bir_mod.types.vectorType(.f32, 3));
    try map.put(.vec4f, try bir_mod.types.vectorType(.f32, 4));
    try map.put(.vec2i, try bir_mod.types.vectorType(.i32, 2));
    try map.put(.vec3i, try bir_mod.types.vectorType(.i32, 3));
    try map.put(.vec4i, try bir_mod.types.vectorType(.i32, 4));
    try map.put(.vec2u, try bir_mod.types.vectorType(.u32, 2));
    try map.put(.vec3u, try bir_mod.types.vectorType(.u32, 3));
    try map.put(.vec4u, try bir_mod.types.vectorType(.u32, 4));
    try map.put(.texture2d, try bir_mod.types.textureType(.tex2d));
    try map.put(.rw_texture2d, try bir_mod.types.textureType(.rw_tex2d));
    try map.put(.sampler, try bir_mod.types.samplerType());
    try map.put(.mat4x4f, try bir_mod.types.add(.{ .matrix = .{ .scalar = .f32, .rows = 4, .cols = 4 } }));

    return map;
}

fn convertIrFunction(allocator: Allocator, bir_mod: *bir.Module, func_id: bir.FunctionId, ir_func: *const gpu_ir.IrFunction, type_map: *const std.AutoHashMap(gpu_ir.TypeRef, TypeId)) !void {
    const fn_ptr = bir_mod.getFunctionMut(func_id);

    const old_block_count = ir_func.blocks.items.len;
    var block_order = std.ArrayList(usize).init(allocator);
    defer block_order.deinit();
    for (0..old_block_count) |i| try block_order.append(i);
    _ = &block_order;

    for (0..old_block_count) |b_idx| {
        const old_block = &ir_func.blocks.items[b_idx];
        _ = try bir_mod.addBlock(func_id, old_block.label);
    }

    var old_to_new_value = std.AutoHashMap(gpu_ir.ValueId, ValueId).init(allocator);
    defer old_to_new_value.deinit();
    try old_to_new_value.ensureTotalCapacity(@intCast(ir_func.blocks.items.len * 32));

    const total_insts = blk: {
        var count: usize = 0;
        for (ir_func.blocks.items) |b| count += b.instrs.items.len;
        break :blk count;
    };
    for (0..total_insts) |_| _ = try fn_ptr.createValue();

    var next_new_val: ValueId = 1;
        for (0..old_block_count) |_b_idx| {
            const old_block = &ir_func.blocks.items[_b_idx];

            for (old_block.instrs.items) |*old_inst| {
                const old_val = old_inst.result;
                const new_val = next_new_val;
                next_new_val += 1;
                old_to_new_value.putAssumeCapacityNoClobber(old_val, new_val);
            }
        }

        for (0..old_block_count) |_b_idx| {
            const old_block = &ir_func.blocks.items[_b_idx];
            const bid = @as(BlockId, @intCast(_b_idx));

            for (old_block.instrs.items) |*old_inst| {
                const bir_inst = try convertInst(allocator, bir_mod, func_id, old_inst, type_map, &old_to_new_value) orelse continue;
                const block = fn_ptr.getBlock(bid);
                const idx = block.instrs.items.len;
                try block.instrs.append(bir_inst);

                if (bir_inst.result != NO_VALUE) {
                    fn_ptr.getValueInfo(bir_inst.result).def = .{ .block = bid, .idx = @as(u32, @intCast(idx)) };
                }

                for (bir_inst.operands) |op_val| {
                    if (op_val != NO_VALUE) {
                        try fn_ptr.getValueInfo(op_val).uses.append(bir_inst.result);
                    }
                }

                {
                    var ref_list = std.ArrayList(ValueId).init(allocator);
                    defer ref_list.deinit();
                    try bir.collectDataRefs(&bir_inst.data, &ref_list);
                    for (ref_list.items) |ref| {
                        if (ref != NO_VALUE) {
                            try fn_ptr.getValueInfo(ref).uses.append(bir_inst.result);
                        }
                    }
                }
            }
        }
}

fn convertInst(allocator: Allocator, _bir_mod: *bir.Module, _func_id: bir.FunctionId, old_inst: *const gpu_ir.IrInst, type_map: *const std.AutoHashMap(gpu_ir.TypeRef, TypeId), value_map: *const std.AutoHashMap(gpu_ir.ValueId, ValueId)) !?bir.Inst {
    _ = _func_id;
    _ = _bir_mod;

    const bir_op = convertOpWithType(old_inst.op, old_inst.ty, old_inst.data) orelse return null;
    const new_val = value_map.get(old_inst.result) orelse return error.ValueNotMapped;
    const bir_ty = type_map.get(old_inst.ty) orelse return error.TypeNotMapped;
    const operands = try remapValues(allocator, old_inst.operands, value_map);
    errdefer if (operands.len > 0) allocator.free(operands);

    const data = try convertData(allocator, old_inst.data, old_inst.op, type_map, value_map);
    errdefer {
        switch (data) {
            .phi_incoming => |v| allocator.free(v),
            .named_call => |v| { allocator.free(v.name); allocator.free(v.args); },
            .gep_info => |v| allocator.free(v.indices),
            .vector_shuffle => |v| allocator.free(v.mask),
            .string => |v| if (v.len > 0) allocator.free(v),
            else => {},
        }
    }

    return bir.Inst{
        .op = bir_op,
        .ty = bir_ty,
        .result = new_val,
        .operands = operands,
        .data = data,
    };
}

fn convertOpWithType(op: gpu_ir.Op, ty: gpu_ir.TypeRef, data: gpu_ir.IrInst.Data) ?bir.Op {
    const is_float = switch (ty) {
        .f32, .f16, .vec2f, .vec3f, .vec4f, .mat4x4f => true,
        else => false,
    };
    return switch (op) {
        .entry_point => null,
        .load => .resource,
        .store => .store,
        .sample => .texture_sample,
        .atomic => .atomic_add,
        .barrier => .barrier,
        .branch => .cond_br,
        .loop => null,
        .phi => .phi,
        .call => .call,
        .ret => switch (data) {
            .block_target => .br,
            .cond_branch => .cond_br,
            else => .ret,
        },
        .@"const" => .@"const",
        .add => if (is_float) .fadd else .add,
        .sub => if (is_float) .fsub else .sub,
        .mul => if (is_float) .fmul else .mul,
        .div => if (is_float) .fdiv else .div,
        .mod => if (is_float) .fmod else .mod,
        .fma => .fma,
        .dot => .vector_dot,
        .exp => .exp,
        .sqrt => .sqrt,
        .rsqrt => .rsqrt,
        .saturate => .saturate,
        .max => .max,
        .min => .min,
        .abs => .abs,
        .floor => .floor,
        .ceil => .ceil,
        .frac => .frac,
        .sin => .sin,
        .cos => .cos,
        .cast => .cast,
        .composite => .composite,
        .extract => .extract,
        .select => .select,
        .lt => if (is_float) .flt else .lt,
        .le => if (is_float) .fle else .le,
        .gt => if (is_float) .fgt else .gt,
        .ge => if (is_float) .fge else .ge,
        .eq => if (is_float) .feq else .eq,
        .ne => if (is_float) .fne else .ne,
        .or_op => .or_op,
        .and_op => .and_op,
        .not => .not,
        .wave_read_lane_first => .wave_read_lane_first,
        .wave_get_lane_index => .wave_get_lane_index,
        .wave_is_first_lane => .wave_is_first_lane,
        .wave_active_all_equal => .wave_active_all_equal,
        .quad_read_across_x => .quad_read_across_x,
        .quad_read_across_y => .quad_read_across_y,
    };
}

fn convertData(allocator: Allocator, old_data: gpu_ir.IrInst.Data, _old_op: gpu_ir.Op, type_map: *const std.AutoHashMap(gpu_ir.TypeRef, TypeId), value_map: *const std.AutoHashMap(gpu_ir.ValueId, ValueId)) !bir.Inst.Data {
    _ = &type_map;
    _ = &value_map;
    _ = &_old_op;
    switch (old_data) {
        .none => return .{ .none = {} },
        .int_val => |v| return .{ .const_data = .{ .int = v } },
        .float_val => |v| return .{ .const_data = .{ .float = v } },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .block_target => |b| return .{ .block_target = b },
        .cond_branch => |cb| {
            const cond = mapValue(cb.cond, value_map);
            return .{ .cond_branch = .{
                .cond = cond,
                .then_block = cb.then_block,
                .else_block = cb.else_block,
            } };
        },
        .phi_incoming => |inc| {
            const new_inc = try allocator.alloc(bir.PhiIncoming, inc.len);
            for (inc, 0..) |item, i| {
                new_inc[i] = .{
                    .value = mapValue(item.value, value_map),
                    .block = item.block,
                };
            }
            return .{ .phi_incoming = new_inc };
        },
        .sample_info => |si| {
            return .{ .sample_info = .{
                .tex = mapValue(si.tex, value_map),
                .sampler = mapValue(si.sampler, value_map),
                .coord = mapValue(si.coord, value_map),
                .lod = NO_VALUE,
                .offset = null,
            } };
        },
        .atomic_info => |ai| {
            return .{ .atomic_info = .{
                .ptr = mapValue(ai.ptr, value_map),
                .val = mapValue(ai.val, value_map),
                .order = .relaxed,
            } };
        },
        .barrier_kind => |bk| return .{ .barrier_kind = @as(bir.BarrierKind, @enumFromInt(@intFromEnum(bk))) },
        .composite_info => return .{ .none = {} },
        .extract_info => |ei| return .{ .extract_info = .{ .index = ei.index } },
        .cast_info => |ci| {
            const from = type_map.get(ci.from) orelse return error.TypeNotMapped;
            const to = type_map.get(ci.to) orelse return error.TypeNotMapped;
            const kind = inferCastKind(ci.from, ci.to);
            return .{ .cast_info = .{ .kind = kind, .from = from, .to = to } };
        },
        .call_info => |ci| {
            if (isIntrinsicMethod(ci.callee) or std.mem.eql(u8, ci.callee, "@array_get")) {
                const new_args = try remapValues(allocator, ci.args, value_map);
                return .{ .named_call = .{
                    .name = try allocator.dupe(u8, ci.callee),
                    .args = new_args,
                } };
            }
            const new_args = try remapValues(allocator, ci.args, value_map);
            return .{ .named_call = .{
                .name = try allocator.dupe(u8, ci.callee),
                .args = new_args,
            } };
        },
        .wave_op => |wo| {
            const source = if (wo.source != 0) mapValue(wo.source, value_map) else NO_VALUE;
            _ = source;
            return .{ .none = {} };
        },
    }
}

fn inferCastKind(from: gpu_ir.TypeRef, to: gpu_ir.TypeRef) bir.CastKind {
    const from_float = isFloatType(from);
    const to_float = isFloatType(to);
    const from_int = isIntType(from);
    const to_int = isIntType(to);
    if (from_float and to_float) return .f2f;
    if (from_float and to_int) return .f2i;
    if (from_int and to_float) return .i2f;
    if (from_int and to_int) return .i2i;
    return .bitcast;
}

fn isFloatType(tr: gpu_ir.TypeRef) bool {
    return switch (tr) {
        .f32, .f16, .vec2f, .vec3f, .vec4f, .mat4x4f => true,
        else => false,
    };
}

fn isIntType(tr: gpu_ir.TypeRef) bool {
    return switch (tr) {
        .i32, .u32, .vec2i, .vec3i, .vec4i, .vec2u, .vec3u, .vec4u => true,
        else => false,
    };
}

fn isIntrinsicMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "SampleLevel") or
        std.mem.eql(u8, name, "Sample") or
        std.mem.eql(u8, name, "Load") or
        std.mem.eql(u8, name, "GetDimensions") or
        std.mem.eql(u8, name, "Gather") or
        std.mem.eql(u8, name, "GatherRed") or
        std.mem.eql(u8, name, "GatherGreen") or
        std.mem.eql(u8, name, "GatherBlue") or
        std.mem.eql(u8, name, "GatherAlpha");
}

fn mapValue(old: gpu_ir.ValueId, value_map: *const std.AutoHashMap(gpu_ir.ValueId, ValueId)) ValueId {
    if (value_map.get(old)) |v| return v;
    return NO_VALUE;
}

fn remapValues(allocator: Allocator, old_operands: []const gpu_ir.ValueId, value_map: *const std.AutoHashMap(gpu_ir.ValueId, ValueId)) ![]ValueId {
    if (old_operands.len == 0) return &.{};
    const new_ops = try allocator.alloc(ValueId, old_operands.len);
    for (old_operands, 0..) |old_v, i| {
        new_ops[i] = mapValue(old_v, value_map);
    }
    return new_ops;
}

fn gpuResourceToIr(res: *const gpu_ast.ResourceDecl) struct { gpu_ir.TypeRef, u8 } {
    return switch (res.gpu_type.kind) {
        .resource_typed => |rt| switch (rt.kind) {
            .texture2d => .{ .texture2d, 't' },
            .rw_texture2d => .{ .rw_texture2d, 'u' },
            else => .{ .texture2d, 't' },
        },
        .resource => |rk| switch (rk) {
            .sampler_state => .{ .sampler, 's' },
            else => .{ .texture2d, 't' },
        },
        else => .{ .texture2d, 't' },
    };
}

fn gpuResourceFormatToIr(res: *const gpu_ast.ResourceDecl) gpu_ir.TypeRef {
    return switch (res.gpu_type.kind) {
        .resource_typed => |rt| gpu_ir.scalarTypeToTypeRefWithWidth(rt.format, rt.width),
        else => .f32,
    };
}

fn cleanupIrFunc(allocator: Allocator, ir_func: *const gpu_ir.IrFunction) void {
    for (ir_func.blocks.items) |b| {
        for (b.instrs.items) |inst| {
            if (inst.operands.len > 0) allocator.free(inst.operands);
            switch (inst.data) {
                .phi_incoming => |v| allocator.free(v),
                .string => |s| if (s.len > 0) allocator.free(s),
                .call_info => |ci| {
                    if (ci.callee.len > 0) allocator.free(ci.callee);
                    if (ci.args.len > 0) allocator.free(ci.args);
                },
                else => {},
            }
        }
        b.instrs.deinit();
        allocator.free(b.label);
    }
    ir_func.blocks.deinit();
    for (ir_func.locals.items) |l| {
        allocator.free(l.name);
        allocator.free(l.array_dims);
    }
    ir_func.locals.deinit();
}

fn extractFuncTypes(allocator: Allocator, globals_lines: []const []const u8) std.StringHashMap(gpu_ir.TypeRef) {
    var map = std.StringHashMap(gpu_ir.TypeRef).init(allocator);
    for (globals_lines) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const lparen = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        const before_paren = trimmed[0..lparen];
        const rp = std.mem.lastIndexOfScalar(u8, before_paren, ' ');
        const rn = std.mem.lastIndexOfScalar(u8, before_paren, '\t');
        const space = @max(rp orelse 0, rn orelse 0);
        if (space == 0 or space + 1 >= before_paren.len) continue;
        const name = before_paren[space + 1 ..];
        const type_str = std.mem.trim(u8, before_paren[0..space], " \t");
        const type_ref = gpu_ir.parseTypeRef(type_str) orelse continue;
        map.put(name, type_ref) catch {};
    }
    return map;
}
