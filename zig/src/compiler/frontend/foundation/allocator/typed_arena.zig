const std = @import("std");

pub fn TypedArena(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = std.ArrayList(T).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        pub fn create(self: *Self, item: T) !*T {
            try self.items.append(item);
            return &self.items.items[self.items.items.len - 1];
        }

        pub fn alloc(self: *Self, n: usize) ![]T {
            const start = self.items.items.len;
            try self.items.resize(start + n);
            return self.items.items[start .. start + n];
        }

        pub fn get(self: *const Self, idx: u32) ?T {
            if (idx < self.items.items.len) return self.items.items[idx];
            return null;
        }

        pub fn getRef(self: *Self, idx: u32) ?*T {
            if (idx < self.items.items.len) return &self.items.items[idx];
            return null;
        }

        pub fn count(self: *const Self) u32 {
            return @intCast(self.items.items.len);
        }

        pub fn slice(self: *const Self) []T {
            return self.items.items;
        }

        pub fn reset(self: *Self) void {
            self.items.clearRetainingCapacity();
        }
    };
}
