const std = @import("std");
const gpu_ir = @import("gpu_ir.zig");
const resource_system = @import("resource_system.zig");

pub const HistoryTexture = struct {
    resource_id: gpu_ir.ResourceId,

    pub fn bind(self: *const HistoryTexture, reg: u32, space: u32, kind: gpu_ir.BindType) gpu_ir.BindEntry {
        return .{
            .key = .{ .reg = reg, .space = space, .kind = kind },
            .resource_id = self.resource_id,
        };
    }
};

pub const HistoryBuffer = struct {
    textures: [2]gpu_ir.ResourceId = [_]gpu_ir.ResourceId{ 0, 0 },
    current_idx: u32 = 0,

    pub fn getCurrent(self: *const HistoryBuffer) HistoryTexture {
        return .{ .resource_id = self.textures[self.current_idx] };
    }

    pub fn getPrevious(self: *const HistoryBuffer) HistoryTexture {
        return .{ .resource_id = self.textures[self.current_idx ^ 1] };
    }

    pub fn flip(self: *HistoryBuffer) void {
        self.current_idx ^= 1;
    }
};

pub const HistoryManager = struct {
    color: HistoryBuffer = .{},
    depth: HistoryBuffer = .{},
    motion: HistoryBuffer = .{},
    exposure: HistoryBuffer = .{},
    frame_index: u64 = 0,
    valid: bool = false,

    pub fn deinit(self: *HistoryManager, pool: *resource_system.ResourcePool) void {
        inline for (.{ "color", "depth", "motion", "exposure" }) |field_name| {
            const hb = &@field(self, field_name);
            for (&hb.textures) |*id| {
                if (id.* != 0) {
                    if (pool.getResource(id.*)) |_| {
                        _ = pool.resources.remove(id.*);
                    }
                    id.* = 0;
                }
            }
        }
    }

    pub fn initColor(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_ir.ResourceFormat,
    ) !void {
        const desc = gpu_ir.TextureDesc{ .width = width, .height = height, .format = format };
        for (&self.color.textures) |*id| {
            id.* = try pool.createTexture2D(desc);
        }
        self.color.current_idx = 0;
    }

    pub fn initDepth(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_ir.ResourceFormat,
    ) !void {
        const desc = gpu_ir.TextureDesc{ .width = width, .height = height, .format = format };
        for (&self.depth.textures) |*id| {
            id.* = try pool.createTexture2D(desc);
        }
        self.depth.current_idx = 0;
    }

    pub fn initMotion(
        self: *HistoryManager,
        pool: *resource_system.ResourcePool,
        width: u32,
        height: u32,
        format: gpu_ir.ResourceFormat,
    ) !void {
        const desc = gpu_ir.TextureDesc{ .width = width, .height = height, .format = format };
        for (&self.motion.textures) |*id| {
            id.* = try pool.createTexture2D(desc);
        }
        self.motion.current_idx = 0;
    }

    pub fn beginFrame(self: *HistoryManager) void {
        self.frame_index += 1;
    }

    pub fn flip(self: *HistoryManager) void {
        self.color.flip();
        self.depth.flip();
        self.motion.flip();
        self.valid = true;
    }

    pub fn reset(self: *HistoryManager) void {
        self.valid = false;
        self.frame_index = 0;
        self.color.current_idx = 0;
        self.depth.current_idx = 0;
        self.motion.current_idx = 0;
    }

    pub fn hasHistory(self: *const HistoryManager) bool {
        return self.valid;
    }
};
