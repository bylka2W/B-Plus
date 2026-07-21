const std = @import("std");
const gpu_types = @import("../compiler/gpu/gpu_types.zig");
const frame_graph = @import("frame_graph.zig");
const resource_system = @import("resource_system.zig");

/// A single resource's lifetime interval [first_pass, last_pass].
pub const LifetimeEntry = struct {
    resource_id: gpu_types.ResourceId,
    first_pass: u32,
    last_pass: u32,
    transient: bool,
};

/// A group of resources with non-overlapping lifetimes that can share memory.
pub const AliasGroup = struct {
    group_id: u32,
    /// Memory requirement: max of all resource sizes in group.
    max_size: u64,
    max_alignment: u64,
    /// Resources assigned to this group (sorted by first_pass).
    resources: []gpu_types.ResourceId,
};

/// Complete lifetime analysis: per-resource intervals + alias groups.
pub const LifetimeGraph = struct {
    entries: []LifetimeEntry,
    groups: []AliasGroup,
    /// resource_id → alias_group_id (only for resources assigned to a group).
    alias_map: std.AutoHashMap(gpu_types.ResourceId, u32),

    pub fn build(
        allocator: std.mem.Allocator,
        gpu_passes: []const frame_graph.GPUPassDesc,
        pool: *resource_system.ResourcePool,
    ) !LifetimeGraph {
        const entries = try computeLifetimes(allocator, gpu_passes, pool);
        errdefer allocator.free(entries);

        var map = std.AutoHashMap(gpu_types.ResourceId, u32).init(allocator);
        errdefer map.deinit();

        const groups = try findAliasGroups(allocator, entries, &map);
        errdefer allocator.free(groups);

        for (groups) |*g| {
            for (g.resources) |rid| {
                if (pool.getResource(rid)) |handle| {
                    const size = resourceSize(handle.desc);
                    g.max_size = @max(g.max_size, size);
                    const group_align: u64 = switch (handle.desc) {
                        .texture2d => 256,
                        .buffer => 16,
                        .sampler => 0,
                    };
                    g.max_alignment = @max(g.max_alignment, group_align);
                }
            }
        }

        return .{
            .entries = entries,
            .groups = groups,
            .alias_map = map,
        };
    }

    pub fn deinit(self: *LifetimeGraph, allocator: std.mem.Allocator) void {
        const groups = @as([]AliasGroup, self.groups);
        for (groups) |*g| allocator.free(g.resources);
        allocator.free(groups);
        allocator.free(self.entries);
        self.alias_map.deinit();
    }

    /// Check if two lifetime intervals can share memory.
    pub fn canAlias(a: LifetimeEntry, b: LifetimeEntry) bool {
        if (!a.transient or !b.transient) return false;
        const a_first = a.first_pass;
        const a_last = a.last_pass;
        const b_first = b.first_pass;
        const b_last = b.last_pass;
        return (a_last < b_first) or (b_last < a_first);
    }

    /// Return the alias group id for a resource, or null if ungrouped.
    pub fn aliasGroup(self: *const LifetimeGraph, resource_id: gpu_types.ResourceId) ?u32 {
        return self.alias_map.get(resource_id);
    }

    /// Estimate resource memory size in bytes.
    fn resourceSize(desc: gpu_types.ResourceDesc) u64 {
        return switch (desc) {
            .buffer => |b| @max(b.size, b.stride * b.elements),
            .texture2d => |t| {
                const bpp: u64 = switch (t.format) {
                    .r32g32b32a32_float => 16,
                    .r32g32b32a32_uint => 16,
                    .r32g32b32a32_sint => 16,
                    .r16g16b16a16_float => 8,
                    .r16g16b16a16_unorm => 8,
                    .r16g16b16a16_uint => 8,
                    .r32g32_float => 8,
                    .r32g32_uint => 8,
                    .r32g32_sint => 8,
                    .r8g8b8a8_unorm => 4,
                    .r8g8b8a8_unorm_srgb => 4,
                    .r8g8b8a8_uint => 4,
                    .r16g16_float => 4,
                    .r16g16_unorm => 4,
                    .r16g16_uint => 4,
                    .r32_float => 4,
                    .r32_uint => 4,
                    .r32_sint => 4,
                    .r8g8_unorm => 2,
                    .r8g8_uint => 2,
                    .r16_float => 2,
                    .r16_unorm => 2,
                    .r16_uint => 2,
                    .r8_unorm => 1,
                    .r8_uint => 1,
                    else => 4,
                };
                return t.width * t.height * bpp * t.array_size;
            },
            .sampler => 0,
        };
    }

    /// Compute lifetime intervals for all resources referenced in gpu passes.
    fn computeLifetimes(
        allocator: std.mem.Allocator,
        gpu_passes: []const frame_graph.GPUPassDesc,
        pool: *resource_system.ResourcePool,
    ) ![]LifetimeEntry {
        var interval_map = std.AutoHashMap(gpu_types.ResourceId, struct { first: u32, last: u32, transient: bool }).init(allocator);
        defer interval_map.deinit();

        for (gpu_passes, 0..) |gp, pi| {
            const pass_idx = @as(u32, @intCast(pi));
            for (gp.bindings.entries) |entry| {
                const gop = try interval_map.getOrPut(entry.resource_id);
                if (!gop.found_existing) {
                    const handle = pool.getResource(entry.resource_id);
                    const is_transient = if (handle) |h| h.desc != .sampler else false;
                    gop.value_ptr.* = .{ .first = pass_idx, .last = pass_idx, .transient = is_transient };
                } else {
                    if (pass_idx < gop.value_ptr.first) gop.value_ptr.first = pass_idx;
                    if (pass_idx > gop.value_ptr.last) gop.value_ptr.last = pass_idx;
                }
            }
        }

        var list = try std.ArrayList(LifetimeEntry).initCapacity(allocator, interval_map.count());
        var it = interval_map.iterator();
        while (it.next()) |entry| {
            list.appendAssumeCapacity(.{
                .resource_id = entry.key_ptr.*,
                .first_pass = entry.value_ptr.first,
                .last_pass = entry.value_ptr.last,
                .transient = entry.value_ptr.transient,
            });
        }
        return list.toOwnedSlice();
    }

    /// Find alias groups: resources with non-overlapping lifetimes share a group.
    /// Greedy interval packing: sort by first_pass, assign to earliest compatible group.
    fn findAliasGroups(
        allocator: std.mem.Allocator,
        entries: []LifetimeEntry,
        alias_map: *std.AutoHashMap(gpu_types.ResourceId, u32),
    ) ![]AliasGroup {
        // Only consider transient resources
        var candidates = std.ArrayList(LifetimeEntry).init(allocator);
        defer candidates.deinit();
        for (entries) |e| {
            if (e.transient) try candidates.append(e);
        }

        if (candidates.items.len == 0) {
            return allocator.alloc(AliasGroup, 0);
        }

        // Sort by first_pass
        std.mem.sort(LifetimeEntry, candidates.items, {}, struct {
            fn less(_: void, a: LifetimeEntry, b: LifetimeEntry) bool {
                if (a.first_pass != b.first_pass) return a.first_pass < b.first_pass;
                return a.resource_id < b.resource_id;
            }
        }.less);

        // Greedy group assignment
        var groups = std.ArrayList(struct {
            last_pass: u32,
            resources: std.ArrayList(gpu_types.ResourceId),
        }).init(allocator);
        defer {
            for (groups.items) |*g| g.resources.deinit();
            groups.deinit();
        }

        for (candidates.items) |candidate| {
            var assigned = false;
            for (groups.items, 0..) |*g, gi| {
                if (g.last_pass < candidate.first_pass) {
                    try g.resources.append(candidate.resource_id);
                    if (candidate.last_pass > g.last_pass) g.last_pass = candidate.last_pass;
                    try alias_map.put(candidate.resource_id, @intCast(gi));
                    assigned = true;
                    break;
                }
            }
            if (!assigned) {
                var new_resources = std.ArrayList(gpu_types.ResourceId).init(allocator);
                try new_resources.append(candidate.resource_id);
                try groups.append(.{
                    .last_pass = candidate.last_pass,
                    .resources = new_resources,
                });
                try alias_map.put(candidate.resource_id, @intCast(groups.items.len - 1));
            }
        }

        // Convert groups to output format
        var result = try std.ArrayList(AliasGroup).initCapacity(allocator, groups.items.len);
        for (groups.items, 0..) |g, gi| {
            const res_slice = try g.resources.toOwnedSlice();
            result.appendAssumeCapacity(.{
                .group_id = @intCast(gi),
                .max_size = 0,
                .max_alignment = 0,
                .resources = res_slice,
            });
        }
        return result.toOwnedSlice();
    }
};
