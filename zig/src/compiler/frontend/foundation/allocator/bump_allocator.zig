const std = @import("std");

pub const BumpAllocator = struct {
    buffer: []u8,
    offset: usize,
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator, size: usize) !BumpAllocator {
        const buf = try backing.alloc(u8, size);
        return .{
            .buffer = buf,
            .offset = 0,
            .backing = backing,
        };
    }

    pub fn deinit(self: *BumpAllocator) void {
        self.backing.free(self.buffer);
    }

    pub fn allocator(self: *BumpAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .free = freeFn,
            },
        };
    }

    pub fn reset(self: *BumpAllocator) void {
        self.offset = 0;
    }

    pub fn bytesAllocated(self: *const BumpAllocator) usize {
        return self.offset;
    }

    pub fn remaining(self: *const BumpAllocator) usize {
        return self.buffer.len - self.offset;
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        const aligned = std.mem.alignForward(usize, self.offset, ptr_align);
        if (aligned + len > self.buffer.len) return null;
        self.offset = aligned + len;
        return @ptrCast(&self.buffer[aligned]);
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        _ = buf_align;
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        if (new_len <= buf.len) return true;
        const end = @intFromPtr(buf.ptr) + buf.len - @intFromPtr(self.buffer.ptr);
        if (end == self.offset and end + (new_len - buf.len) <= self.buffer.len) {
            self.offset = end + (new_len - buf.len);
            return true;
        }
        return false;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        _ = buf_align;
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        const end = @intFromPtr(buf.ptr) + buf.len - @intFromPtr(self.buffer.ptr);
        if (end == self.offset) {
            self.offset = @intFromPtr(buf.ptr) - @intFromPtr(self.buffer.ptr);
        }
    }
};
