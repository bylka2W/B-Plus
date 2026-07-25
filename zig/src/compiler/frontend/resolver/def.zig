const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");
const source_span = @import("../source/location/span.zig");

pub const DefId = ids.DefId;
pub const SymbolId = ids.SymbolId;
pub const ScopeId = ids.ScopeId;
pub const SourceSpan = source_span.SourceSpan;

pub const DefKind = enum {
    function,
    struct_type,
    enum_type,
    enum_variant,
    trait,
    impl,
    type_alias,
    module,
    import,
    local,
    parameter,
    field,
    loop_label,
};

pub const Def = struct {
    id: DefId,
    kind: DefKind,
    name: SymbolId,
    owner: DefId,
    span: SourceSpan,

    pub const INVALID = Def{
        .id = DefId.INVALID,
        .kind = .local,
        .name = SymbolId.INVALID,
        .owner = DefId.INVALID,
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
    };
};

pub const DefTable = struct {
    defs: std.ArrayList(Def),
    by_name: std.AutoHashMap(SymbolId, DefId),

    pub fn init(allocator: std.mem.Allocator) DefTable {
        return .{
            .defs = std.ArrayList(Def).init(allocator),
            .by_name = std.AutoHashMap(SymbolId, DefId).init(allocator),
        };
    }

    pub fn deinit(self: *DefTable) void {
        self.defs.deinit();
        self.by_name.deinit();
    }

    pub fn addDef(self: *DefTable, def: Def) DefId {
        const idx: u32 = @intCast(self.defs.items.len);
        self.defs.append(def) catch return DefId.INVALID;
        return DefId.new(idx);
    }

    pub fn getDef(self: *const DefTable, id: DefId) ?*Def {
        if (!id.isValid()) return null;
        if (id.index >= self.defs.items.len) return null;
        return &self.defs.items[id.index];
    }

    pub fn addName(self: *DefTable, name: SymbolId, id: DefId) void {
        self.by_name.put(name, id) catch {};
    }

    pub fn lookupName(self: *const DefTable, name: SymbolId) ?DefId {
        return self.by_name.get(name);
    }
};
