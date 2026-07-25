const std = @import("std");
const string_pool = @import("string_pool.zig");

pub const StringInterner = struct {
    pool: *string_pool.StringPool,
    index: std.StringHashMap(u32),

    pub fn init(pool: *string_pool.StringPool) StringInterner {
        return .{
            .pool = pool,
            .index = std.StringHashMap(u32).init(pool.allocator),
        };
    }

    pub fn deinit(self: *StringInterner) void {
        self.index.deinit();
    }

    pub fn intern(self: *StringInterner, str: []const u8) !u32 {
        if (self.index.get(str)) |id| return id;
        const id = try self.pool.intern(str);
        try self.index.put(str, id);
        return id;
    }

    pub fn resolve(self: *const StringInterner, id: u32) []const u8 {
        return self.pool.resolve(id);
    }

    pub fn eql(_: *const StringInterner, a: u32, b: u32) bool {
        return a == b;
    }

    pub fn count(self: *const StringInterner) u32 {
        return self.pool.count();
    }
};
