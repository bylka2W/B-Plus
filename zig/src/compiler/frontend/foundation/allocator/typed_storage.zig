const std = @import("std");

pub fn TypedStorage(comptime T: type) type {
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

        pub fn push(self: *Self, item: T) !u32 {
            const idx: u32 = @intCast(self.items.items.len);
            try self.items.append(item);
            return idx;
        }

        pub fn get(self: *const Self, idx: u32) ?T {
            if (idx < self.items.items.len) return self.items.items[idx];
            return null;
        }

        pub fn getMut(self: *Self, idx: u32) ?*T {
            if (idx < self.items.items.len) return &self.items.items[idx];
            return null;
        }

        pub fn len(self: *const Self) u32 {
            return @intCast(self.items.items.len);
        }

        pub fn slice(self: *const Self) []const T {
            return self.items.items;
        }
    };
}

pub fn IndexedArena(comptime T: type) type {
    return struct {
        storage: TypedStorage(T),
        free_list: std.ArrayList(u32),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .storage = TypedStorage(T).init(allocator),
                .free_list = std.ArrayList(u32).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.storage.deinit();
            self.free_list.deinit();
        }

        pub fn alloc(self: *Self, item: T) !u32 {
            if (self.free_list.items.len > 0) {
                const idx = self.free_list.pop();
                self.storage.items.items[idx] = item;
                return idx;
            }
            return self.storage.push(item);
        }

        pub fn get(self: *const Self, idx: u32) ?T {
            return self.storage.get(idx);
        }

        pub fn getMut(self: *Self, idx: u32) ?*T {
            return self.storage.getMut(idx);
        }

        pub fn dealloc(self: *Self, idx: u32) void {
            self.free_list.append(idx) catch {};
        }

        pub fn count(self: *const Self) u32 {
            return self.storage.len();
        }
    };
}
