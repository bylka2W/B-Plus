const std = @import("std");
const frame_graph = @import("frame_graph.zig");
const gpu_ir = @import("gpu_ir.zig");
const resource_system = @import("resource_system.zig");

pub const ResourceAccess = enum(u8) {
    read,
    write,
    read_write,
};

pub const ResourceNode = struct {
    id: u32,
    resource_id: gpu_ir.ResourceId,
    passes: []const u32,
    state: gpu_ir.ResourceState = .common,
    access: ResourceAccess = .read,
    transient: bool = false,
};

pub const TransientAlloc = struct {
    resource_id: gpu_ir.ResourceId,
    desc: gpu_ir.ResourceDesc,
    first_pass: u32,
    last_pass: u32,
};

pub const LifetimeEntry = struct {
    resource_id: gpu_ir.ResourceId,
    first_pass: u32,
    last_pass: u32,
};

pub const BarrierSlot = struct {
    pass_index: u32,
    barrier: gpu_ir.BarrierDesc,
};

pub const RenderPlan = struct {
    nodes: []frame_graph.ExecutionNode,
    edges: []frame_graph.DependencyEdge,
    budget_us: u32,
    gpu_passes: []const frame_graph.GPUPassDesc,
    transients: []const TransientAlloc,
    auto_barriers: []const BarrierSlot,
};

pub const RenderGraph = struct {
    allocator: std.mem.Allocator,
    pool: *resource_system.ResourcePool,

    pub fn init(allocator: std.mem.Allocator, pool: *resource_system.ResourcePool) RenderGraph {
        return .{ .allocator = allocator, .pool = pool };
    }

    pub fn compile(
        self: *RenderGraph,
        frames: []const frame_graph.Pass,
        gpu_passes: []const frame_graph.GPUPassDesc,
        budget_us: u32,
    ) !RenderPlan {
        const fg = frame_graph.FrameGraph.init(frames);
        var plan = try fg.compile(self.allocator, budget_us);
        errdefer frame_graph.FrameGraph.deinitPlan(self.allocator, &plan);

        const lifetimes = try self.computeLifetimes(gpu_passes);
        defer self.allocator.free(lifetimes);

        const transients = try self.collectTransients(lifetimes);
        errdefer self.allocator.free(transients);

        const barriers = try self.inferBarriers(gpu_passes, lifetimes);
        errdefer self.allocator.free(barriers);

        return RenderPlan{
            .nodes = plan.nodes,
            .edges = plan.edges,
            .budget_us = plan.budget_us,
            .gpu_passes = gpu_passes,
            .transients = transients,
            .auto_barriers = barriers,
        };
    }

    pub fn computeLifetimes(
        self: *RenderGraph,
        gpu_passes: []const frame_graph.GPUPassDesc,
    ) ![]LifetimeEntry {
        var map = std.AutoHashMap(gpu_ir.ResourceId, struct { first: u32, last: u32 }).init(self.allocator);
        defer map.deinit();

        for (gpu_passes, 0..) |gp, pi| {
            const pass_idx = @as(u32, @intCast(pi));
            for (gp.bindings.entries) |entry| {
                const gop = try map.getOrPut(entry.resource_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .first = pass_idx, .last = pass_idx };
                } else {
                    if (pass_idx < gop.value_ptr.first) gop.value_ptr.first = pass_idx;
                    if (pass_idx > gop.value_ptr.last) gop.value_ptr.last = pass_idx;
                }
            }
        }

        var result = try std.ArrayList(LifetimeEntry).initCapacity(self.allocator, map.count());
        var it = map.iterator();
        while (it.next()) |entry| {
            result.appendAssumeCapacity(.{
                .resource_id = entry.key_ptr.*,
                .first_pass = entry.value_ptr.first,
                .last_pass = entry.value_ptr.last,
            });
        }
        return result.toOwnedSlice();
    }

    pub fn collectTransients(
        self: *RenderGraph,
        lifetimes: []const LifetimeEntry,
    ) ![]TransientAlloc {
        var list = std.ArrayList(TransientAlloc).init(self.allocator);
        for (lifetimes) |lt| {
            const handle = self.pool.getResource(lt.resource_id) orelse continue;
            if (handle.desc == .texture2d or handle.desc == .buffer) {
                try list.append(.{
                    .resource_id = lt.resource_id,
                    .desc = handle.desc,
                    .first_pass = lt.first_pass,
                    .last_pass = lt.last_pass,
                });
            }
        }
        return list.toOwnedSlice();
    }

    pub fn inferBarriers(
        self: *RenderGraph,
        gpu_passes: []const frame_graph.GPUPassDesc,
        lifetimes: []const LifetimeEntry,
    ) ![]BarrierSlot {
        _ = lifetimes;
        var state_map = std.AutoHashMap(gpu_ir.ResourceId, gpu_ir.ResourceState).init(self.allocator);
        defer state_map.deinit();

        var list = std.ArrayList(BarrierSlot).init(self.allocator);

        for (gpu_passes, 0..) |gp, pi| {
            const pass_idx = @as(u32, @intCast(pi));
            const want_read = gpu_ir.ResourceState.non_pixel_shader_resource;
            const want_write = gpu_ir.ResourceState.unordered_access;

            for (gp.bindings.entries) |entry| {
                const current_state = state_map.get(entry.resource_id) orelse gpu_ir.ResourceState.common;
                const desired_state = switch (entry.key.kind) {
                    .srv => want_read,
                    .uav => want_write,
                    .cbv => continue,
                    .sampler => continue,
                };
                if (current_state != desired_state) {
                    try list.append(.{
                        .pass_index = pass_idx,
                        .barrier = .{
                            .resource_id = entry.resource_id,
                            .barrier_type = .transition,
                            .state_before = current_state,
                            .state_after = desired_state,
                        },
                    });
                    try state_map.put(entry.resource_id, desired_state);
                }
            }
        }

        return list.toOwnedSlice();
    }

    pub fn allocateTransients(self: *RenderGraph, plan: *RenderPlan) !void {
        for (plan.transients) |t| {
            _ = self.pool.getResource(t.resource_id) orelse {
                switch (t.desc) {
                    .texture2d => |td| {
                        _ = try self.pool.createTexture2D(td);
                    },
                    .buffer => |bd| {
                        _ = try self.pool.createBuffer(bd);
                    },
                    .sampler => {},
                }
            };
        }
    }

    pub fn releaseTransients(self: *RenderGraph, plan: *RenderPlan) void {
        for (plan.transients) |t| {
            if (self.pool.getResource(t.resource_id)) |handle| {
                if (handle.d3d_resource != null) {
                    _ = self.pool.resources.remove(t.resource_id);
                }
            }
        }
    }

    pub fn deinitPlan(allocator: std.mem.Allocator, plan: *const RenderPlan) void {
        frame_graph.FrameGraph.deinitPlan(allocator, &.{
            .nodes = plan.nodes,
            .edges = plan.edges,
            .budget_us = plan.budget_us,
        });
        allocator.free(plan.transients);
        allocator.free(plan.auto_barriers);
    }
};
