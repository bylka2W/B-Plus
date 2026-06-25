const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ast = @import("gpu_ast.zig");

pub const ValueId = u32;
pub const BlockId = u32;

pub const Op = enum {
    entry_point,
    load,
    store,
    sample,
    atomic,
    barrier,
    branch,
    loop,
    phi,
    call,
    ret,
    @"const",
    add,
    sub,
    mul,
    div,
    fma,
    dot,
    exp,
    sqrt,
    rsqrt,
    saturate,
    max,
    min,
    abs,
    floor,
    ceil,
    frac,
    sin,
    cos,
    cast,
    composite,
    extract,
};

pub const TypeRef = enum {
    void,
    f32,
    i32,
    u32,
    f16,
    vec2f,
    vec3f,
    vec4f,
    vec2i,
    vec3i,
    vec4i,
    vec2u,
    vec3u,
    vec4u,
    texture2d,
    rw_texture2d,
    sampler,
};

pub const IrInst = struct {
    op: Op,
    ty: TypeRef,
    result: ValueId,
    operands: []ValueId,
    data: Data,

    pub const Data = union {
        none: void,
        int_val: i64,
        float_val: f64,
        string: []const u8,
        block_target: BlockId,
        cond_branch: struct { cond: ValueId, then_block: BlockId, else_block: BlockId },
        phi_incoming: []struct { value: ValueId, block: BlockId },
        sample_info: struct { tex: ValueId, sampler: ValueId, coord: ValueId },
        atomic_info: struct { ptr: ValueId, val: ValueId, op: AtomicOp },
        barrier_kind: BarrierKind,
        composite_info: struct { count: u32 },
        extract_info: struct { index: u32 },
        cast_info: struct { from: TypeRef, to: TypeRef },
        call_info: struct { callee: []const u8, args: []ValueId },
    };

    pub const AtomicOp = enum { add, sub, min, max, and_op, or_op, xor_op, exchange, compare_exchange };
    pub const BarrierKind = enum { group, device, all };
};

pub const IrBasicBlock = struct {
    label: []const u8,
    instrs: std.ArrayList(IrInst),
    next_value_id: ValueId,
};

pub fn scalarTypeToTypeRef(st: gpu_ast.ScalarType) TypeRef {
    return switch (st) {
        .f32 => .f32,
        .i32 => .i32,
        .u32 => .u32,
        .f16 => .f16,
        .boolean => .u32,
    };
}

pub fn scalarTypeToTypeRefWithWidth(st: gpu_ast.ScalarType, w: gpu_ast.VectorWidth) TypeRef {
    const width_val = @intFromEnum(w);
    if (width_val == 1) return scalarTypeToTypeRef(st);
    return switch (st) {
        .f32 => @as(TypeRef, @enumFromInt(@intFromEnum(TypeRef.vec2f) + (width_val - 2))),
        .i32 => @as(TypeRef, @enumFromInt(@intFromEnum(TypeRef.vec2i) + (width_val - 2))),
        .u32 => @as(TypeRef, @enumFromInt(@intFromEnum(TypeRef.vec2u) + (width_val - 2))),
        else => scalarTypeToTypeRef(st),
    };
}

pub const IrResourceDecl = struct {
    name: []const u8,
    type_ref: TypeRef,
    binding_prefix: u8,
    binding_reg: u32,
    format: TypeRef,
};

pub const IrCbufferMember = struct {
    name: []const u8,
    type_ref: TypeRef,
    slot: u32,
};

pub const IrFunction = struct {
    name: []const u8,
    blocks: std.ArrayList(IrBasicBlock),
    next_block_id: BlockId,
    numthreads: struct { x: u32, y: u32, z: u32 },
    x_param: []const u8,
    y_param: []const u8,
    passthrough_body: std.ArrayList([]const u8),
    globals_lines: std.ArrayList([]const u8),
};

pub const IrModule = struct {
    allocator: Allocator,
    resources: std.ArrayList(IrResourceDecl),
    cbuffer_members: std.ArrayList(IrCbufferMember),
    functions: std.ArrayList(IrFunction),

    pub fn deinit(self: *IrModule) void {
        for (self.functions.items) |*f| {
            for (f.blocks.items) |*b| {
                for (b.instrs.items) |*inst| {
                    if (inst.operands.len > 0) inst.operands.deinit();
                    if (inst.data == .phi_incoming) self.allocator.free(inst.data.phi_incoming);
                    if (inst.data == .call_info) self.allocator.free(inst.data.call_info.args);
                }
                b.instrs.deinit();
            }
            f.blocks.deinit();
        }
        self.functions.deinit();
        self.resources.deinit();
        self.cbuffer_members.deinit();
    }
};
