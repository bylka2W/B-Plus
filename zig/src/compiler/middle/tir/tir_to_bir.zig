const std = @import("std");
const Allocator = std.mem.Allocator;
const tir = @import("../tir/types.zig");
const bir_mod = @import("../bir/core/module.zig");
const bir_inst = @import("../bir/core/instruction.zig");
const bir_types = @import("../bir/core/types.zig");
const bir_value = @import("../bir/core/value.zig");
const bir_func = @import("../bir/core/function.zig");
const bir_block = @import("../bir/core/block.zig");

const Inst = bir_inst.Inst;
const ValueId = bir_value.ValueId;
const BlockId = bir_value.BlockId;
const FunctionId = bir_value.FunctionId;
const NO_VALUE = bir_value.NO_VALUE;
const TypeId = bir_types.TypeId;
const ScalarKind = bir_types.ScalarKind;
const AddressSpace = bir_types.AddressSpace;
const CallingConvention = bir_func.CallingConvention;

pub fn lowerModule(allocator: Allocator, tir_mod: *const tir.Module) !bir_mod.Module {
    var module = bir_mod.Module.init(allocator);
    errdefer module.deinit();

    try mapTypes(tir_mod, &module);

    for (tir_mod.functions.items) |*tir_func| {
        try lowerFunction(&module, tir_func);
    }

    return module;
}

fn mapTypes(tir_mod: *const tir.Module, bir: *bir_mod.Module) !void {
    for (tir_mod.types.types.items) |t| {
        const kind: bir_types.Type.Kind = switch (t.kind) {
            .void => .void,
            .scalar => |sk| .{ .scalar = mapScalarKind(sk) },
            .pointer => |p| .{ .pointer = .{ .elem = p.elem, .space = mapAddressSpace(p.space) } },
            .array => |a| .{ .array = .{ .elem = a.elem, .len = a.len } },
            .struct_type => |s| .{ .struct_type = .{
                .name = try bir.allocator.dupe(u8, s.name),
                .fields = try bir.allocator.dupe(TypeId, s.fields),
                .offsets = try bir.allocator.dupe(u32, s.offsets),
                .size_val = 0,
                .alignment_val = 0,
            } },
            .function => |f| .{ .function = .{
                .params = try bir.allocator.dupe(TypeId, f.params),
                .return_type = f.ret,
            } },
            .custom_opaque => |n| .{ .custom_opaque = try bir.allocator.dupe(u8, n) },
        };
        _ = try bir.types.add(kind);
    }
}

fn mapScalarKind(sk: tir.ScalarKind) ScalarKind {
    return switch (sk) {
        .i1 => .i1,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f32 => .f32,
        .f64 => .f64,
    };
}

fn mapAddressSpace(as: tir.AddressSpace) AddressSpace {
    return switch (as) {
        .generic => .generic,
        .global => .global,
        .shared => .shared,
        .@"const" => .@"const",
        .local => .local,
    };
}

fn lowerFunction(module: *bir_mod.Module, tir_func: *const tir.Function) !void {
    const cc: CallingConvention = switch (tir_func.linkage) {
        .@"export" => .c,
        .internal => .internal,
        .entry => .internal,
    };
    const fid = try module.addFunction(tir_func.name, tir_func.ret_type, cc);

    {
        const bir_fn = module.getFunctionMut(fid);
        const owned_params = try module.allocator.alloc(bir_func.FuncParam, tir_func.params.len);
        const owned_values = try module.allocator.alloc(ValueId, tir_func.params.len);
        for (tir_func.params, 0..) |param, i| {
            owned_params[i] = .{
                .name = try module.allocator.dupe(u8, param.name),
                .ty = param.ty,
            };
            owned_values[i] = try bir_fn.createValue();
        }
        bir_fn.params = owned_params;
        bir_fn.param_values = owned_values;
    }

    var block_map = std.AutoHashMap(tir.BlockId, BlockId).init(module.allocator);
    defer block_map.deinit();

    for (tir_func.blocks.items, 0..) |_, i| {
        const tir_bid: tir.BlockId = @intCast(i);
        const bir_bid = try module.addBlock(fid, tir_func.blocks.items[i].label);
        try block_map.put(tir_bid, bir_bid);
    }

    for (tir_func.blocks.items, 0..) |tir_blk, blk_idx| {
        const tir_bid: tir.BlockId = @intCast(blk_idx);
        const bir_bid = block_map.get(tir_bid).?;

        for (tir_blk.instrs.items) |tir_inst| {
            const bir_inst_val = try convertInst(module, tir_func, tir_inst, &block_map);
            _ = try module.addInst(fid, bir_bid, bir_inst_val);
        }
    }
}

fn convertInst(
    module: *bir_mod.Module,
    tir_func: *const tir.Function,
    tir_inst: tir.Instruction,
    block_map: *const std.AutoHashMap(tir.BlockId, BlockId),
) !Inst {
    const op = mapOp(tir_inst.op);
    const result = tir_inst.result;

    const owned_ops = if (tir_inst.operands.len > 0)
        try module.allocator.dupe(ValueId, tir_inst.operands)
    else
        &.{};

    const data: Inst.Data = switch (tir_inst.data) {
        .none => .none,
        .const_data => |cd| switch (cd) {
            .int => |v| .{ .const_data = .{ .int = v } },
            .float => |v| .{ .const_data = .{ .float = v } },
            .bool_val => |v| .{ .const_data = .{ .bool = v } },
            .none => .{ .const_data = .{ .zero = {} } },
        },
        .named_call => |nc| blk: {
            const owned_name = try module.allocator.dupe(u8, nc.name);
            const owned_args = if (nc.args.len > 0)
                try module.allocator.dupe(ValueId, nc.args)
            else
                &.{};
            break :blk .{ .named_call = .{ .name = owned_name, .args = owned_args } };
        },
        .block_target => |bt| blk: {
            const mapped = block_map.get(bt) orelse bt;
            break :blk .{ .block_target = mapped };
        },
        .cond_branch => |cb| blk: {
            const then_mapped = block_map.get(cb.then_block) orelse cb.then_block;
            const else_mapped = block_map.get(cb.else_block) orelse cb.else_block;
            break :blk .{ .cond_branch = .{
                .cond = cb.cond,
                .then_block = then_mapped,
                .else_block = else_mapped,
            } };
        },
        .phi_entry => |pe| blk: {
            const incoming = try module.allocator.alloc(bir_inst.PhiIncoming, 1);
            incoming[0] = .{
                .value = pe.incoming_val,
                .block = block_map.get(pe.incoming_block) orelse pe.incoming_block,
            };
            break :blk .{ .phi_incoming = incoming };
        },
    };

    return .{
        .op = op,
        .ty = tir_inst.ty,
        .result = result,
        .operands = owned_ops,
        .data = data,
    };
}

fn mapOp(op: tir.Op) bir_inst.Op {
    return switch (op) {
        .br => .br,
        .cond_br => .cond_br,
        .ret => .ret,
        .alloca => .alloca,
        .load => .load,
        .store => .store,
        .const_int => .@"const",
        .const_float => .@"const",
        .const_bool => .@"const",
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .neg => .neg,
        .fadd => .fadd,
        .fsub => .fsub,
        .fmul => .fmul,
        .fdiv => .fdiv,
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .feq => .feq,
        .fne => .fne,
        .flt => .flt,
        .fle => .fle,
        .fgt => .fgt,
        .fge => .fge,
        .and_op => .and_op,
        .or_op => .or_op,
        .not => .not,
        .xor_op => .xor_op,
        .call => .call,
        .alloca_array => .getelementptr,
        .ptr_offset => .ptr_offset,
        .cast => .cast,
        .bitcast => .bitcast,
        .sext => .sext,
        .zext => .zext,
        .trunc => .trunc,
        .fptosi => .fptosi,
        .sitofp => .sitofp,
        .fpext => .fpext,
        .phi => .phi,
    };
}
