const std = @import("std");

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    offset: usize,
    entries: std.ArrayList(Entry),
    index: std.StringHashMap(u32),

    pub const Entry = struct {
        start: u32,
        len: u32,
    };

    pub fn init(allocator: std.mem.Allocator) !StringPool {
        const initial = try allocator.alloc(u8, 64 * 1024);
        return .{
            .allocator = allocator,
            .buffer = initial,
            .offset = 0,
            .entries = std.ArrayList(Entry).init(allocator),
            .index = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *StringPool) void {
        self.allocator.free(self.buffer);
        self.entries.deinit();
        self.index.deinit();
    }

    pub fn intern(self: *StringPool, str: []const u8) !u32 {
        if (self.index.get(str)) |id| return id;
        if (str.len + self.offset > self.buffer.len) {
            const new_size = @max(self.buffer.len * 2, str.len + 1024);
            const new_buf = try self.allocator.alloc(u8, new_size);
            @memcpy(new_buf[0..self.offset], self.buffer[0..self.offset]);
            self.allocator.free(self.buffer);
            self.buffer = new_buf;
        }
        const start: u32 = @intCast(self.offset);
        @memcpy(self.buffer[self.offset .. self.offset + str.len], str);
        self.offset += str.len;
        self.buffer[self.offset] = 0;
        self.offset += 1;

        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(.{ .start = start, .len = @intCast(str.len) });
        try self.index.put(self.buffer[start..][0..str.len], id);
        return id;
    }

    pub fn resolve(self: *const StringPool, id: u32) []const u8 {
        if (id < self.entries.items.len) {
            const e = self.entries.items[id];
            return self.buffer[e.start..][0..e.len];
        }
        return "";
    }

    pub fn count(self: *const StringPool) u32 {
        return @intCast(self.entries.items.len);
    }
};
