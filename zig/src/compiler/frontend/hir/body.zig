const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");

pub const BodyId = ids.BodyId;
pub const SymbolId = ids.SymbolId;
pub const TypeId = ids.TypeId;
pub const ExprId = ids.ExprId;
pub const OwnerId = ids.OwnerId;
pub const DefId = ids.DefId;

pub const HirBody = struct {
    owner: OwnerId,
    entry: ExprId,
    local_count: u32,

    pub const ParamIndex = u32;
    pub const LocalIndex = u32;
};
