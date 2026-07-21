const std = @import("std");
const value = @import("value.zig");
const types = @import("types.zig");
const ValueId = value.ValueId;
const BlockId = value.BlockId;
const NO_VALUE = value.NO_VALUE;
const TypeId = types.TypeId;

pub const Op = enum {
    br,
    cond_br,
    ret,
    unreachable_op,

    alloca,
    load,
    store,
    ptr_offset,
    ptr_to_int,
    int_to_ptr,

    add,
    sub,
    mul,
    div,
    mod,
    neg,
    max,
    min,

    fadd,
    fsub,
    fmul,
    fdiv,
    fmod,
    fneg,
    fma,
    sqrt,
    rsqrt,
    exp,
    log,
    sin,
    cos,
    floor,
    ceil,
    frac,
    abs,
    saturate,
    lerp,

    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    feq,
    fne,
    flt,
    fle,
    fgt,
    fge,

    or_op,
    and_op,
    xor_op,
    not,
    shl,
    shr,
    shra,

    cast,
    bitcast,
    sext,
    zext,
    trunc,
    fptosi,
    sitofp,
    fpext,
    fptrunc,

    composite,
    extract,
    insert,
    shuffle,

    splat,
    extract_element,
    insert_element,
    vector_add,
    vector_sub,
    vector_mul,
    vector_div,
    vector_dot,
    vector_cross,
    vector_normalize,
    vector_length,
    vector_reflect,
    vector_refract,

    matrix_mul,
    matrix_transpose,
    matrix_inverse,
    matrix_determinant,

    fence,
    atomic_add,
    atomic_sub,
    atomic_min,
    atomic_max,
    atomic_and,
    atomic_or,
    atomic_xor,
    atomic_xchg,
    atomic_cmpxchg,

    thread_id,
    block_id,
    thread_count,
    block_count,
    barrier,
    groupshared_barrier,
    wave_get_lane_index,
    wave_is_first_lane,
    wave_read_lane_first,
    wave_active_all_equal,
    quad_read_across_x,
    quad_read_across_y,
    groupshared_alloc,

    texture_sample,
    texture_load,
    texture_store,
    texture_gather,
    texture_query_dimensions,
    texture_query_lod,

    call,
    phi,
    @"const",
    resource,
    select,
    getelementptr,
    branch_on_bit,
};

pub const ConstData = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    @"undefined": void,
    zero: void,
};

pub const PhiIncoming = struct { value: ValueId, block: BlockId };

pub const MemoryOrder = enum {
    relaxed,
    acquire,
    release,
    acq_rel,
    seq_cst,
};

pub const AtomicOp = struct {
    ptr: ValueId,
    val: ValueId,
    order: MemoryOrder,
};

pub const CastKind = enum {
    f2i,
    i2f,
    f2f,
    i2i,
    bitcast,
    ptr2int,
    int2ptr,
    zeroext,
    signext,
    trunc,
};

pub const BarrierKind = enum {
    group,
    device,
    all,
};

pub const SampleInfo = struct {
    tex: ValueId,
    sampler: ValueId,
    coord: ValueId,
    lod: ?ValueId,
    offset: ?ValueId,
};

pub const GepInfo = struct {
    ptr: ValueId,
    indices: []ValueId,
    result_elem_type: TypeId,
};

pub const CallInfo = struct {
    callee: ValueId,
    args: []ValueId,
};

pub const Inst = struct {
    op: Op,
    ty: TypeId,
    result: ValueId,
    operands: []ValueId,
    data: Data,

    pub const Data = union(enum) {
        none: void,
        const_data: ConstData,
        string: []const u8,
        block_target: BlockId,
        cond_branch: struct { cond: ValueId, then_block: BlockId, else_block: BlockId },
        phi_incoming: []PhiIncoming,
        cast_info: struct { kind: CastKind, from: TypeId, to: TypeId },
        atomic_info: AtomicOp,
        sample_info: SampleInfo,
        barrier_kind: BarrierKind,
        gep_info: GepInfo,
        call_info: CallInfo,
        named_call: struct { name: []const u8, args: []ValueId },
        extract_info: struct { index: u32 },
        texture_store_info: struct { tex: ValueId, coord_x: ValueId, coord_y: ValueId, val: ValueId },
        vector_shuffle: struct { a: ValueId, b: ValueId, mask: []u32 },
        group_info: struct { dim: u32 },
        fence_info: MemoryOrder,
        groupshared_size: u32,
        branch_on_bit: struct { bit: ValueId, then_block: BlockId, else_block: BlockId },
    };

    pub fn deinit(self: *Inst, allocator: std.mem.Allocator) void {
        if (self.operands.len > 0) allocator.free(self.operands);
        switch (self.data) {
            .phi_incoming => |v| allocator.free(v),
            .gep_info => |v| allocator.free(v.indices),
            .call_info => |v| allocator.free(v.args),
            .named_call => |v| {
                allocator.free(v.name);
                allocator.free(v.args);
            },
            .vector_shuffle => |v| allocator.free(v.mask),
            .string => |v| if (v.len > 0) allocator.free(v),
            else => {},
        }
    }
};

pub fn collectDataRefs(data: *const Inst.Data, result: *std.ArrayList(ValueId)) !void {
    switch (data.*) {
        .phi_incoming => |incoming| {
            try result.ensureUnusedCapacity(incoming.len);
            for (incoming) |inc| result.appendAssumeCapacity(inc.value);
        },
        .gep_info => |gi| {
            try result.append(gi.ptr);
            try result.appendSlice(gi.indices);
        },
        .call_info => |ci| {
            try result.append(ci.callee);
            try result.appendSlice(ci.args);
        },
        .atomic_info => |ai| {
            try result.append(ai.ptr);
            try result.append(ai.val);
        },
        .sample_info => |si| {
            try result.append(si.tex);
            try result.append(si.sampler);
            try result.append(si.coord);
            if (si.lod) |v| try result.append(v);
            if (si.offset) |v| try result.append(v);
        },
        .texture_store_info => |tsi| {
            try result.append(tsi.tex);
            try result.append(tsi.coord_x);
            try result.append(tsi.coord_y);
            try result.append(tsi.val);
        },
        .named_call => |nc| try result.appendSlice(nc.args),
        .cond_branch => |cb| try result.append(cb.cond),
        .branch_on_bit => |bb| try result.append(bb.bit),
        else => {},
    }
}
