const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const types_mod = @import("bir_types.zig");
const TypeId = types_mod.TypeId;

const Op = bir.Op;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
