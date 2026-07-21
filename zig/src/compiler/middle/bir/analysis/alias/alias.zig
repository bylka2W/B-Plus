const std = @import("std");
const bir = @import("../../bir.zig");

pub const AliasResult = enum {
    NoAlias,
    MayAlias,
    MustAlias,
};

const PtrKind = enum { resource, alloca, unknown };

pub fn query(func: *const bir.Function, a: bir.ValueId, b: bir.ValueId) AliasResult {
    if (a == b) return .MustAlias;
    const ka = resolvePtrKind(func, a);
    const kb = resolvePtrKind(func, b);
    if (ka == .unknown or kb == .unknown) return .MayAlias;
    if (ka == .resource and kb == .resource) return .NoAlias;
    if (ka == .alloca and kb == .alloca) return .NoAlias;
    if ((ka == .resource and kb == .alloca) or (ka == .alloca and kb == .resource)) return .NoAlias;
    return .MayAlias;
}

fn resolvePtrKind(func: *const bir.Function, val: bir.ValueId) PtrKind {
    if (val == bir.NO_VALUE) return .unknown;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == bir.INVALID_ID) return .unknown;
    const block = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= block.instrs.items.len) return .unknown;
    const inst = &block.instrs.items[vi.def.idx];
    return switch (inst.op) {
        .resource => .resource,
        .alloca => .alloca,
        else => .unknown,
    };
}
