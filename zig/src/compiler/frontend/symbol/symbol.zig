const std = @import("std");
const intern = @import("../intern/identifier_table.zig");
const source = @import("../source/location/span.zig");

pub const IdentifierId = intern.IdentifierId;
pub const SourceSpan = source.SourceSpan;

pub const SymbolKind = enum {
    local,
    param,
    global,
    function,
    struct_type,
    enum_type,
    constant,
    module,
    label,
    builtin,
};

pub const SymbolId = u32;
pub const ScopeId = u32;

pub const Symbol = struct {
    id: SymbolId,
    name_id: IdentifierId,
    kind: SymbolKind,
    scope_id: ScopeId,
    type_id: u32,
    declared: ?SourceSpan,
    flags: packed struct {
        is_mutable: bool = true,
        is_pub: bool = false,
        is_extern: bool = false,
        is_comptime: bool = false,
    } = .{},
};
