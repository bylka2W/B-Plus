const std = @import("std");
const string_pool = @import("string_pool.zig");

pub const SymbolInterner = struct {
    pool: *string_pool.StringPool,
    index: std.StringHashMap(u32),

    pub fn init(pool: *string_pool.StringPool) SymbolInterner {
        return .{
            .pool = pool,
            .index = std.StringHashMap(u32).init(pool.allocator),
        };
    }

    pub fn deinit(self: *SymbolInterner) void {
        self.index.deinit();
    }

    pub fn intern(self: *SymbolInterner, name: []const u8) !u32 {
        if (self.index.get(name)) |id| return id;
        const id = try self.pool.intern(name);
        try self.index.put(name, id);
        return id;
    }

    pub fn resolve(self: *const SymbolInterner, id: u32) []const u8 {
        return self.pool.resolve(id);
    }

    pub fn count(self: *const SymbolInterner) u32 {
        return self.pool.count();
    }
};
