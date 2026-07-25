const std = @import("std");

pub const RegionAllocator = struct {
    regions: std.ArrayList([]u8),
    current_region: ?[]u8,
    offset: usize,
    region_size: usize,
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator, region_size: usize) RegionAllocator {
        return .{
            .regions = std.ArrayList([]u8).init(backing),
            .current_region = null,
            .offset = 0,
            .region_size = region_size,
            .backing = backing,
        };
    }

    pub fn deinit(self: *RegionAllocator) void {
        for (self.regions.items) |r| {
            self.backing.free(r);
        }
        self.regions.deinit();
    }

    pub fn allocator(self: *RegionAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .free = freeFn,
            },
        };
    }

    pub fn reset(self: *RegionAllocator) void {
        self.offset = 0;
        self.current_region = null;
    }

    pub fn memoryUsed(self: *const RegionAllocator) usize {
        return self.regions.items.len * self.region_size + self.offset;
    }

    fn ensureSpace(self: *RegionAllocator, len: usize, align_: std.mem.Alignment) ?[*]u8 {
        if (len > self.region_size) return null;
        const region = self.current_region orelse {
            const new_region = self.backing.alloc(u8, self.region_size) catch return null;
            self.regions.append(new_region) catch {
                self.backing.free(new_region);
                return null;
            };
            self.current_region = new_region;
            self.offset = 0;
            return self.ensureSpace(len, align_);
        };
        const aligned = std.mem.alignForward(usize, self.offset, @intFromEnum(align_));
        if (aligned + len > region.len) {
            self.current_region = null;
            self.offset = 0;
            return self.ensureSpace(len, align_);
        }
        self.offset = aligned + len;
        return @ptrCast(&region[aligned]);
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *RegionAllocator = @ptrCast(@alignCast(ctx));
        return self.ensureSpace(len, ptr_align);
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        _ = buf_align;
        const self: *RegionAllocator = @ptrCast(@alignCast(ctx));
        _ = self;
        return new_len <= buf.len;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        _ = buf_align;
        _ = buf;
        _ = ctx;
    }
};
