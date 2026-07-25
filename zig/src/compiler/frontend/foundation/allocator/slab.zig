const std = @import("std");

pub fn SlabAllocator(comptime T: type) type {
    return struct {
        chunks: std.ArrayList([]T),
        free_list: std.ArrayList(u32),
        chunk_size: usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, chunk_size: usize) Self {
            return .{
                .chunks = std.ArrayList([]T).init(allocator),
                .free_list = std.ArrayList(u32).init(allocator),
                .chunk_size = chunk_size,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.chunks.items) |chunk| {
                self.allocator.free(chunk);
            }
            self.chunks.deinit();
            self.free_list.deinit();
        }

        pub fn alloc(self: *Self) !u32 {
            if (self.free_list.items.len > 0) {
                return self.free_list.pop();
            }
            if (self.chunks.items.len == 0 or self.chunks.items[self.chunks.items.len - 1].len == 0) {
                const chunk = try self.allocator.alloc(T, self.chunk_size);
                try self.chunks.append(chunk);
            }
            const last = &self.chunks.items[self.chunks.items.len - 1];
            const id: u32 = @intCast((self.chunks.items.len - 1) * self.chunk_size + (self.chunk_size - last.len));
            _ = last.len;
            _ = id;
            return 0;
        }

        pub fn get(self: *const Self, id: u32) ?T {
            const chunk_idx = id / self.chunk_size;
            const offset = id % self.chunk_size;
            if (chunk_idx < self.chunks.items.len and offset < self.chunks.items[chunk_idx].len) {
                return self.chunks.items[chunk_idx][offset];
            }
            return null;
        }

        pub fn count(self: *const Self) u32 {
            var total: u32 = 0;
            for (self.chunks.items) |chunk| {
                total += @intCast(chunk.len);
            }
            return total - @as(u32, @intCast(self.free_list.items.len));
        }
    };
}
