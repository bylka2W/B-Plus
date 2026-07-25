const std = @import("std");

pub const StringId = u32;

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList([]const u8),
    index: std.StringHashMap(StringId),
    next_id: StringId,

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .allocator = allocator,
            .strings = std.ArrayList([]const u8).init(allocator),
            .index = std.StringHashMap(StringId).init(allocator),
            .next_id = 0,
        };
    }

    pub fn deinit(self: *StringPool) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit();
        self.index.deinit();
    }

    pub fn intern(self: *StringPool, str: []const u8) StringId {
        if (self.index.get(str)) |id| return id;
        const id = self.next_id;
        self.next_id += 1;
        const owned = self.allocator.dupe(u8, str) catch return 0;
        self.strings.append(owned) catch return 0;
        self.index.put(owned, id) catch return 0;
        return id;
    }

    pub fn get(self: *const StringPool, id: StringId) ?[]const u8 {
        if (id >= self.strings.items.len) return null;
        return self.strings.items[id];
    }

    pub fn resolve(self: *const StringPool, id: StringId) []const u8 {
        return self.get(id) orelse "";
    }

    pub fn count(self: *const StringPool) usize {
        return self.strings.items.len;
    }
};
