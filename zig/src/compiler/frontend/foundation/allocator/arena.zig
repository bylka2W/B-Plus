const std = @import("std");

pub const ArenaAllocator = struct {
    backing: std.mem.Allocator,
    state: std.heap.ArenaAllocator.State,

    pub fn init(backing: std.mem.Allocator) ArenaAllocator {
        return .{
            .backing = backing,
            .state = std.heap.ArenaAllocator.State.init(backing),
        };
    }

    pub fn deinit(self: *ArenaAllocator) void {
        self.state.deinit();
    }

    pub fn allocator(self: *ArenaAllocator) std.mem.Allocator {
        return self.state.allocator();
    }

    pub fn reset(self: *ArenaAllocator) void {
        self.state.reset();
    }

    pub fn childAllocator(self: *const ArenaAllocator) std.mem.Allocator {
        return self.backing;
    }
};

test "arena basic" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), buf.len);
}
