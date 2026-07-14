const std = @import("std");
const gpu_types = @import("gpu_types.zig");
const resource_system = @import("resource_system.zig");

/// Ring-buffer depth for frame generation.
/// FSR 3.1 needs N-1 and N-2 for interpolation; N-3 for optical flow confidence.
pub const HISTORY_DEPTH = 4;

/// A single history slot — wraps a texture resource.
pub const HistorySlot = struct {
    resource_id: gpu_types.ResourceId = 0,

    pub fn bind(self: *const HistorySlot, reg: u32, space: u32, kind: gpu_types.BindingKind) gpu_types.BindEntry {
        return .{
            .key = .{ .reg = reg, .space = space, .kind = kind },
            .resource_id = self.resource_id,
        };
    }
};

/// Ring buffer of history textures with generation tracking.
pub const HistoryRing = struct {
    slots: [HISTORY_DEPTH]gpu_types.ResourceId = [_]gpu_types.ResourceId{0} ** HISTORY_DEPTH,
    write_idx: u32 = 0,
    count: u32 = 0,

    pub fn getCurrent(self: *const HistoryRing) HistorySlot {
        if (self.count == 0) return .{};
        return .{ .resource_id = self.slots[self.write_idx] };
    }

    pub fn getPrevious(self: *const HistoryRing, offset: u32) HistorySlot {
        if (offset >= self.count) return .{};
        const read_idx = (self.write_idx + HISTORY_DEPTH - offset) % HISTORY_DEPTH;
        return .{ .resource_id = self.slots[read_idx] };
    }

    pub fn getAll(self: *const HistoryRing, comptime count: u32) [count]HistorySlot {
        var result: [count]HistorySlot = undefined;
        for (0..@min(count, self.count)) |i| {
            result[i] = self.getPrevious(i);
        }
        return result;
    }

    pub fn push(self: *HistoryRing, resource_id: gpu_types.ResourceId) void {
        self.write_idx = (self.write_idx + 1) % HISTORY_DEPTH;
        self.slots[self.write_idx] = resource_id;
        if (self.count < HISTORY_DEPTH) self.count += 1;
    }

    pub fn flip(_: *HistoryRing) void {
        // write_idx stays — next frame overwrites oldest slot
    }

    pub fn hasHistory(self: *const HistoryRing) bool {
        // Need at least 2 frames (prev + current) for temporal reprojection.
        return self.count >= 2;
    }

    pub fn hasFullHistory(self: *const HistoryRing) bool {
        return self.count >= HISTORY_DEPTH;
    }
};

/// Full history manager for FSR 3.1 temporal resources.
pub const HistoryManager = struct {
    color: HistoryRing = .{},
    depth: HistoryRing = .{},
    motion: HistoryRing = .{},
    exposure: HistoryRing = .{},
    reactive: HistoryRing = .{},
    compositing: HistoryRing = .{},
    frame_index: u64 = 0,
    valid: bool = false,

    pub fn deinit(self: *HistoryManager, pool: *resource_system.ResourcePool) void {
        inline for (.{ "color", "depth", "motion", "exposure", "reactive", "compositing" }) |field_name| {
            const ring = &@field(self, field_name);
            for (&ring.slots) |*id| {
                if (id.* != 0) {
                    if (pool.getResource(id.*)) |_| {
                        _ = pool.resources.remove(id.*);
                    }
                    id.* = 0;
                }
            }
        }
    }

    fn initRing(
        ring: *HistoryRing,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_types.ResourceFormat,
    ) !void {
        const desc = gpu_types.TextureDesc{ .width = width, .height = height, .format = format };
        for (&ring.slots) |*id| {
            id.* = try pool.createTexture2D(desc);
        }
        ring.write_idx = 0;
        ring.count = 0;
    }

    pub fn initColor(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_types.ResourceFormat,
    ) !void {
        try initRing(&self.color, pool, width, height, format);
    }

    pub fn initDepth(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_types.ResourceFormat,
    ) !void {
        try initRing(&self.depth, pool, width, height, format);
    }

    pub fn initMotion(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_types.ResourceFormat,
    ) !void {
        try initRing(&self.motion, pool, width, height, format);
    }

    pub fn initExposure(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_types.ResourceFormat,
    ) !void {
        try initRing(&self.exposure, pool, width, height, format);
    }

    pub fn initReactive(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_types.ResourceFormat,
    ) !void {
        try initRing(&self.reactive, pool, width, height, format);
    }

    pub fn initCompositing(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_types.ResourceFormat,
    ) !void {
        try initRing(&self.compositing, pool, width, height, format);
    }

    pub fn beginFrame(self: *HistoryManager) void {
        self.frame_index += 1;
    }

    pub fn flip(self: *HistoryManager) void {
        self.color.flip();
        self.depth.flip();
        self.motion.flip();
        self.exposure.flip();
        self.reactive.flip();
        self.compositing.flip();
        self.valid = true;
    }

    pub fn pushFrame(
        self: *HistoryManager,
        color_id: gpu_types.ResourceId,
        depth_id: gpu_types.ResourceId,
        motion_id: gpu_types.ResourceId,
    ) void {
        self.color.push(color_id);
        self.depth.push(depth_id);
        self.motion.push(motion_id);
        self.valid = true;
    }

    pub fn reset(self: *HistoryManager) void {
        self.valid = false;
        self.frame_index = 0;
        self.color = .{};
        self.depth = .{};
        self.motion = .{};
        self.exposure = .{};
        self.reactive = .{};
        self.compositing = .{};
    }

    pub fn hasHistory(self: *const HistoryManager) bool {
        return self.valid and self.color.hasHistory();
    }

    pub fn hasFullHistory(self: *const HistoryManager) bool {
        return self.valid and self.color.hasFullHistory();
    }

    pub fn canGenerateFrame(self: *const HistoryManager) bool {
        // Need at least 2 previous frames for interpolation
        return self.hasHistory() and self.color.count >= 2;
    }
};
