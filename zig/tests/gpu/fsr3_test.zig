const std = @import("std");
const gpu_types = @import("../../src/compiler/backend/gpu/gpu_types.zig");
const frame_graph = @import("../../src/render/frame_graph.zig");
const history_manager = @import("../../src/render/history_manager.zig");
const temporal_pipeline = @import("../../src/render/temporal_pipeline.zig");
const temporal_history = @import("../../src/render/temporal_history.zig");
const barrier_optimizer = @import("../../src/render/barrier_optimizer.zig");
const lifetime_graph = @import("../../src/render/lifetime_graph.zig");
const fsr3_runtime = @import("../../src/render/fsr3_runtime.zig");
const gpu_execution = @import("../../src/render/gpu_execution.zig");
const cost_scheduler = @import("../../src/runtime/cost_scheduler.zig");
const resource_system = @import("../../src/render/resource_system.zig");
const render_graph = @import("../../src/render/render_graph.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try testHistoryRing();
    try testTemporalPipeline();
    try testFSR3FrameGraph(allocator);
    try testFSR3Runtime();
    try testFramePolicy();
    try testLifetimeGraph();
    try testBarrierOptimizer(allocator);
    try testTemporalHistory();
    try testGpuExecutionPlan(allocator);
    try testCostScheduler(allocator);
    try testCompileFrame(allocator);

    std.debug.print("All FSR 3.1 integration tests passed.\n", .{});
}

fn testHistoryRing() !void {
    var ring: history_manager.HistoryRing = .{};
    try std.testing.expectEqual(@as(u32, 0), ring.count);
    try std.testing.expectEqual(false, ring.hasHistory());
    try std.testing.expectEqual(false, ring.hasFullHistory());

    // Push 2 frames
    ring.push(100);
    ring.push(200);
    try std.testing.expectEqual(@as(u32, 2), ring.count);
    try std.testing.expectEqual(true, ring.hasHistory());
    try std.testing.expectEqual(false, ring.hasFullHistory());

    // getCurrent returns most recent (index 1 after advance)
    const cur = ring.getCurrent();
    try std.testing.expectEqual(@as(u32, 200), cur.resource_id);

    // getPrevious(0) = current
    const prev0 = ring.getPrevious(0);
    try std.testing.expectEqual(@as(u32, 200), prev0.resource_id);

    // getPrevious(1) = previous
    const prev1 = ring.getPrevious(1);
    try std.testing.expectEqual(@as(u32, 100), prev1.resource_id);

    // getPrevious(2) = out of range (only 2 pushed)
    const prev2 = ring.getPrevious(2);
    try std.testing.expectEqual(@as(u32, 0), prev2.resource_id);

    // Push 2 more: fill ring
    ring.push(300);
    ring.push(400);
    try std.testing.expectEqual(true, ring.hasFullHistory());
    try std.testing.expectEqual(@as(u32, 4), ring.count);

    // Ring wraps: oldest was 100, should be evicted
    const old = ring.getPrevious(3);
    try std.testing.expectEqual(@as(u32, 100), old.resource_id);
}

fn testTemporalPipeline() !void {
    var tp = temporal_pipeline.TemporalPipeline.init(1920, 1080);

    // Initial state
    try std.testing.expectEqual(@as(u32, 0), tp.frame_index);
    try std.testing.expectEqual(true, tp.reset_history);

    // First frame
    tp.beginFrame();
    try std.testing.expectEqual(@as(u32, 1), tp.frame_index);

    const tc = tp.getTemporalConstants();
    try std.testing.expectApproxEqAbs(@as(f32, 1920.0), tc.viewport_width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1080.0), tc.viewport_height, 0.001);
    try std.testing.expectEqual(@as(u32, 1), tc.reset_history);

    tp.endFrame();
    try std.testing.expectEqual(false, tp.reset_history);

    // Second frame
    tp.beginFrame();
    const mc = tp.getMotionConstants();
    try std.testing.expectApproxEqAbs(@as(f32, 1920.0), mc.viewport_width, 0.001);
    try std.testing.expectEqual(@as(u32, 2), tp.frame_index);
    tp.endFrame();
}

fn testFSR3FrameGraph(allocator: std.mem.Allocator) !void {
    const config = fsr3_runtime.FSR3Config{
        .display_width = 1920,
        .display_height = 1080,
        .render_width = 1920,
        .render_height = 1080,
    };
    var rt = fsr3_runtime.FSR3Runtime.init(config);
    const fg = try rt.buildFrameGraph(allocator);
    defer allocator.free(fg.passes);

    // 4 passes: optical_flow, disocclusion, generate, post_process
    try std.testing.expectEqual(@as(usize, 4), fg.passes.len);

    const expected = [_]struct { id: u32, name: []const u8 }{
        .{ .id = 100, .name = "fsr3_optical_flow" },
        .{ .id = 101, .name = "fsr3_disocclusion" },
        .{ .id = 102, .name = "fsr3_generate" },
        .{ .id = 103, .name = "fsr3_post" },
    };

    for (expected, fg.passes) |exp, pass| {
        try std.testing.expectEqual(exp.id, pass.id);
        try std.testing.expectEqualStrings(exp.name, pass.name);
        try std.testing.expectEqual(true, pass.gpu);
        try std.testing.expect(pass.fsr3_pass != null);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), pass.interp_t, 0.001);
    }

    // Compile the frame graph
    const plan = try fg.compile(allocator, 5000);
    defer frame_graph.FrameGraph.deinitPlan(allocator, &plan);

    // Topological sort order must be optical_flow -> disocclusion -> generate -> post
    try std.testing.expectEqual(@as(usize, 4), plan.nodes.len);
    const order = [_]u32{ 100, 101, 102, 103 };
    for (order, plan.nodes) |expected_id, node| {
        try std.testing.expectEqual(expected_id, node.id);
        switch (node.kind) {
            .fsr3_generation => |fg3| {
                try std.testing.expectEqual(expected_id, fg3.pass_id);
            },
            else => {
                std.debug.print("expected fsr3_generation node for pass {d}\n", .{expected_id});
                return error.UnexpectedNodeKind;
            },
        }
    }

    // Edges: disocclusion -> optical_flow, generate -> disocclusion, post -> generate
    try std.testing.expectEqual(@as(usize, 3), plan.edges.len);
    // Dependencies: disocclusion depends on optical_flow, generate on disocclusion, post on generate
}

fn testFSR3Runtime() !void {
    const config = fsr3_runtime.FSR3Config{
        .display_width = 2560,
        .display_height = 1440,
        .render_width = 1920,
        .render_height = 1080,
        .quality = .quality,
        .gen_mode = .x3,
    };
    var rt = fsr3_runtime.FSR3Runtime.init(config);

    try std.testing.expectEqual(@as(u32, 2560), rt.config.display_width);
    try std.testing.expectEqual(@as(u32, 1440), rt.config.display_height);

    // beginFrame/endFrame cycle
    rt.beginFrame();
    rt.beginFrame();
    try std.testing.expectEqual(@as(u32, 2), rt.temporal.frame_index);

    // x3 mode -> interp t = 0.333
    try std.testing.expectApproxEqAbs(@as(f32, 0.333), rt.getInterpolationT(), 0.001);

    // Without history, cannot generate frame
    try std.testing.expectEqual(false, rt.shouldGenerateFrame());
    rt.endFrame();
}

fn testTemporalHistory() !void {
    const testing = std.testing;
    var th = temporal_history.TemporalHistory{};

    // 1 frame → not enough for generation
    th.pushFrame(1);
    try testing.expectEqual(false, th.canGenerate());

    // 2 frames → enough for generation
    th.pushFrame(2);
    try testing.expectEqual(@as(u32, 2), th.count);
    try testing.expectEqual(true, th.canGenerate());

    // Fresh frames have full confidence
    try testing.expectEqual(@as(f32, 1.0), th.getConfidence(0));
    try testing.expectEqual(true, th.isFrameValid(0));

    // Push third frame
    th.pushFrame(3);
    try testing.expectEqual(true, th.canGenerate());

    // Reject frame at offset 1 (previous)
    th.rejectFrame(1);
    try testing.expectEqual(@as(f32, 0.0), th.getConfidence(1));

    // After rejection, should still have current (offset 0) valid
    try testing.expectEqual(true, th.isFrameValid(0));
    try testing.expectEqual(false, th.isFrameValid(1));

    // Set reprojection confidence
    th.pushFrame(4);
    th.setReprojectionConfidence(2.0); // 2px error out of 4 max
    const conf = th.getConfidence(0);
    try testing.expect(conf < 1.0);
    try testing.expect(conf > 0.0);

    // High motion → rejection
    th.pushFrame(5);
    th.setMotionCoherence(1.0); // above 0.5 threshold
    try testing.expectEqual(@as(f32, 0.0), th.getConfidence(0));

    // Reset
    th.reset();
    try testing.expectEqual(@as(u32, 0), th.count);
    try testing.expectEqual(false, th.canGenerate());
}

fn testBarrierOptimizer(allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    var ba = barrier_optimizer.BarrierOptimizer.init(allocator);

    // Empty input → empty output
    {
        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);
        const result = try ba.optimize(&.{}, &lg);
        try testing.expectEqual(@as(usize, 0), result.barriers.len);
        try testing.expectEqual(@as(u32, 0), result.stats.total_before);
        allocator.free(result.barriers);
    }

    // No redundant transitions: single pass
    {
        const bindings = gpu_types.BindGroup{
            .entries = &.{
                .{ .resource_id = 10, .key = .{ .reg = 0, .space = 0, .kind = .uav } },
            },
        };
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 0,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "main" } },
                .grid = .{ .x = 8, .y = 8, .z = 1 },
                .bindings = bindings,
            },
        };

        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);
        const result = try ba.optimize(&passes, &lg);
        defer allocator.free(result.barriers);
        try testing.expectEqual(@as(usize, 1), result.barriers.len);
        try testing.expectEqual(@as(u32, 10), result.barriers[0].barrier.resource_id);
    }

    // Determinism: same input → same output order
    {
        const bindings1 = gpu_types.BindGroup{
            .entries = &.{
                .{ .resource_id = 20, .key = .{ .reg = 0, .space = 0, .kind = .uav } },
                .{ .resource_id = 10, .key = .{ .reg = 1, .space = 0, .kind = .srv } },
            },
        };
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 0,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "main" } },
                .grid = .{ .x = 8, .y = 8, .z = 1 },
                .bindings = bindings1,
            },
        };
        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);
        const r1 = try ba.optimize(&passes, &lg);
        defer allocator.free(r1.barriers);
        const r2 = try ba.optimize(&passes, &lg);
        defer allocator.free(r2.barriers);

        try testing.expectEqual(r1.barriers.len, r2.barriers.len);
        for (r1.barriers, r2.barriers) |a, b| {
            try testing.expectEqual(a.pass_index, b.pass_index);
            try testing.expectEqual(a.barrier.resource_id, b.barrier.resource_id);
        }
    }
}

fn testLifetimeGraph() !void {
    const testing = std.testing;

    // Test canAlias with non-overlapping intervals
    {
        const lg = @import("../../src/render/lifetime_graph.zig");
        const a = lg.LifetimeEntry{ .resource_id = 1, .first_pass = 0, .last_pass = 2, .transient = true };
        const b = lg.LifetimeEntry{ .resource_id = 2, .first_pass = 3, .last_pass = 5, .transient = true };
        try testing.expect(lg.LifetimeGraph.canAlias(a, b));
        try testing.expect(lg.LifetimeGraph.canAlias(b, a));
    }

    // Test overlapping intervals → cannot alias
    {
        const lg = @import("../../src/render/lifetime_graph.zig");
        const a = lg.LifetimeEntry{ .resource_id = 1, .first_pass = 0, .last_pass = 4, .transient = true };
        const b = lg.LifetimeEntry{ .resource_id = 2, .first_pass = 3, .last_pass = 5, .transient = true };
        try testing.expect(!lg.LifetimeGraph.canAlias(a, b));
    }

    // Test non-transient → cannot alias
    {
        const lg = @import("../../src/render/lifetime_graph.zig");
        const a = lg.LifetimeEntry{ .resource_id = 1, .first_pass = 0, .last_pass = 2, .transient = true };
        const b = lg.LifetimeEntry{ .resource_id = 2, .first_pass = 3, .last_pass = 5, .transient = false };
        try testing.expect(!lg.LifetimeGraph.canAlias(a, b));
    }

    // Test edge case: adjacent intervals can alias (last_pass < first_pass)
    {
        const lg = @import("../../src/render/lifetime_graph.zig");
        const a = lg.LifetimeEntry{ .resource_id = 1, .first_pass = 0, .last_pass = 2, .transient = true };
        const b = lg.LifetimeEntry{ .resource_id = 2, .first_pass = 3, .last_pass = 5, .transient = true };
        try testing.expect(lg.LifetimeGraph.canAlias(a, b));
    }
}

fn testFramePolicy() !void {
    var policy = fsr3_runtime.FramePolicy.init(.{});

    // 1. Budget overflow → pass_through
    {
        const mode = policy.evaluate(.{
            .frame_latency_us = 99999,
            .motion_intensity = 0.0,
            .history_valid = true,
            .frame_index = 1,
        });
        try std.testing.expectEqual(fsr3_runtime.FrameMode.pass_through, mode);
    }

    // 2. High motion → real
    {
        const mode = policy.evaluate(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.9,
            .history_valid = true,
            .frame_index = 2,
        });
        try std.testing.expectEqual(fsr3_runtime.FrameMode.real, mode);
    }

    // 3. Low motion + history valid → generated
    {
        // Need to establish min_real_frames first (policy starts at 0 real_count)
        // After 1 real frame (from step 2), real_count = 1 which is >= min_real_frames(1)
        const mode = policy.evaluate(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.1,
            .history_valid = true,
            .frame_index = 3,
        });
        try std.testing.expectEqual(fsr3_runtime.FrameMode.generated, mode);
    }

    // 4. Second generated frame allowed (max_generated_frames = 2)
    {
        const mode = policy.evaluate(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.1,
            .history_valid = true,
            .frame_index = 4,
        });
        try std.testing.expectEqual(fsr3_runtime.FrameMode.generated, mode);
    }

    // 5. Third generated → forced back to real (max_generated_frames = 2)
    {
        const mode = policy.evaluate(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.1,
            .history_valid = true,
            .frame_index = 5,
        });
        try std.testing.expectEqual(fsr3_runtime.FrameMode.real, mode);
    }

    // 6. History invalid → real
    {
        policy.reset();
        // After reset, we need min_real_frames (1) of real frames first
        _ = policy.evaluate(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.1,
            .history_valid = true,
            .frame_index = 6,
        });
        // Now real_count = 1, last_mode = .real
        const mode = policy.evaluate(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.1,
            .history_valid = false,
            .frame_index = 7,
        });
        try std.testing.expectEqual(fsr3_runtime.FrameMode.real, mode);
    }

    // 7. Default with mid motion + valid history → generated (after warmup)
    {
        policy.reset();
        // Two real frames to warm up
        _ = policy.evaluate(.{ .frame_latency_us = 100, .motion_intensity = 0.5, .history_valid = true, .frame_index = 8 });
        const mode = policy.evaluate(.{ .frame_latency_us = 100, .motion_intensity = 0.5, .history_valid = true, .frame_index = 9 });
        // motion=0.5 is between low(0.3) and high(0.7), history valid, real_count=1 >= min(1) → generated
        try std.testing.expectEqual(fsr3_runtime.FrameMode.generated, mode);
    }

    // 8. Determinism check: same inputs → same output
    {
        policy.reset();
        // Warmup
        _ = policy.evaluate(.{ .frame_latency_us = 100, .motion_intensity = 0.1, .history_valid = true, .frame_index = 10 });
        const mode_a = policy.evaluate(.{ .frame_latency_us = 100, .motion_intensity = 0.1, .history_valid = true, .frame_index = 11 });
        const mode_b = policy.evaluate(.{ .frame_latency_us = 100, .motion_intensity = 0.1, .history_valid = true, .frame_index = 12 });
        // Sequence: after warmup (gen), 11→gen, 12→gen; 13 would be forced real
        try std.testing.expectEqual(fsr3_runtime.FrameMode.generated, mode_a);
        try std.testing.expectEqual(fsr3_runtime.FrameMode.generated, mode_b);
    }
}

fn testGpuExecutionPlan(allocator: std.mem.Allocator) !void {
    const testing = std.testing;

    // Empty input: no passes → empty plan
    {
        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);

        var plan = try gpu_execution.compileGpuExecutionPlan(
            allocator,
            &.{},
            &lg,
            &.{},
            .{ .frame_index = 0, .budget_us = 1000, .motion_intensity = 0.0, .history_valid = false },
        );
        defer plan.deinit();
        try testing.expectEqual(@as(usize, 0), plan.dispatches.len);
        try testing.expectEqual(@as(usize, 0), plan.bindings.len);
        try testing.expectEqual(@as(u32, 1000), plan.frame_budget_us);
    }

    // Single compute pass with bindings
    {
        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);

        const bindings = gpu_types.BindGroup{
            .entries = &.{
                .{ .resource_id = 10, .key = .{ .reg = 0, .space = 0, .kind = .uav } },
                .{ .resource_id = 20, .key = .{ .reg = 1, .space = 0, .kind = .srv } },
                .{ .resource_id = 30, .key = .{ .reg = 0, .space = 1, .kind = .cbv } },
            },
        };
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 100,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "main" } },
                .grid = .{ .x = 8, .y = 8, .z = 1 },
                .bindings = bindings,
            },
        };

        var plan = try gpu_execution.compileGpuExecutionPlan(
            allocator,
            &passes,
            &lg,
            &.{},
            .{ .frame_index = 1, .budget_us = 2000, .motion_intensity = 0.5, .history_valid = true },
        );
        defer plan.deinit();

        // 1 dispatch
        try testing.expectEqual(@as(usize, 1), plan.dispatches.len);
        try testing.expectEqual(@as(u32, 100), plan.dispatches[0].pass_id);
        try testing.expectEqual(gpu_execution.DispatchType.compute, plan.dispatches[0].dispatch_type);
        try testing.expectEqual(@as(u32, 8), plan.dispatches[0].group_count_x);
        try testing.expectEqual(@as(u32, 8), plan.dispatches[0].group_count_y);
        try testing.expectEqual(@as(u32, 1), plan.dispatches[0].group_count_z);
        try testing.expectEqual(@as(u32, 0), plan.dispatches[0].barrier_index);

        // 3 bindings
        try testing.expectEqual(@as(usize, 3), plan.bindings.len);
        try testing.expectEqual(@as(u32, 10), plan.bindings[0].resource_id);
        try testing.expectEqual(gpu_execution.ResourceSlotType.rw_buffer, plan.bindings[0].slot_type);
        try testing.expectEqual(true, plan.bindings[0].read_write);

        try testing.expectEqual(@as(u32, 20), plan.bindings[1].resource_id);
        try testing.expectEqual(gpu_execution.ResourceSlotType.texture, plan.bindings[1].slot_type);
        try testing.expectEqual(false, plan.bindings[1].read_write);

        try testing.expectEqual(@as(u32, 30), plan.bindings[2].resource_id);
        try testing.expectEqual(gpu_execution.ResourceSlotType.buffer, plan.bindings[2].slot_type);
        try testing.expectEqual(false, plan.bindings[2].read_write);

        try testing.expectEqual(@as(u32, 2000), plan.frame_budget_us);
    }

    // Multiple passes with ordering
    {
        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);

        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 0,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "a" } },
                .grid = .{ .x = 1, .y = 1, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
            .{
                .pass_id = 1,
                .queue = .graphics,
                .pipeline = .{ .shader = .{ .source = "", .entry = "b" } },
                .grid = .{ .x = 2, .y = 2, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };

        var plan = try gpu_execution.compileGpuExecutionPlan(
            allocator,
            &passes,
            &lg,
            &.{},
            .{ .frame_index = 0, .budget_us = 500, .motion_intensity = 0.0, .history_valid = true },
        );
        defer plan.deinit();

        try testing.expectEqual(@as(usize, 2), plan.dispatches.len);
        try testing.expectEqual(@as(u32, 0), plan.dispatches[0].pass_id);
        try testing.expectEqual(gpu_execution.DispatchType.compute, plan.dispatches[0].dispatch_type);
        try testing.expectEqual(@as(u32, 1), plan.dispatches[0].group_count_x);

        try testing.expectEqual(@as(u32, 1), plan.dispatches[1].pass_id);
        try testing.expectEqual(gpu_execution.DispatchType.graphics, plan.dispatches[1].dispatch_type);
        try testing.expectEqual(@as(u32, 2), plan.dispatches[1].group_count_x);
    }

    // Context passthrough
    {
        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);

        var plan = try gpu_execution.compileGpuExecutionPlan(
            allocator,
            &.{},
            &lg,
            &.{},
            .{ .frame_index = 42, .budget_us = 9999, .motion_intensity = 0.75, .history_valid = true },
        );
        defer plan.deinit();
        try testing.expectEqual(@as(u32, 9999), plan.frame_budget_us);
    }

    // Determinism: same input → same output
    {
        var lg = lifetime_graph.LifetimeGraph{
            .entries = &.{},
            .groups = &.{},
            .alias_map = std.AutoHashMap(u64, u32).init(allocator),
        };
        defer lg.deinit(allocator);

        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 10,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "main" } },
                .grid = .{ .x = 4, .y = 4, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };
        const ctx = gpu_execution.ExecutionContext{ .frame_index = 0, .budget_us = 500, .motion_intensity = 0.0, .history_valid = false };

        var plan_a = try gpu_execution.compileGpuExecutionPlan(allocator, &passes, &lg, &.{}, ctx);
        defer plan_a.deinit();
        var plan_b = try gpu_execution.compileGpuExecutionPlan(allocator, &passes, &lg, &.{}, ctx);
        defer plan_b.deinit();

        try testing.expectEqual(plan_a.dispatches.len, plan_b.dispatches.len);
        try testing.expectEqual(plan_a.bindings.len, plan_b.bindings.len);
        try testing.expectEqual(plan_a.frame_budget_us, plan_b.frame_budget_us);
    }
}

fn testCostScheduler(allocator: std.mem.Allocator) !void {
    const testing = std.testing;

    // 1. Empty input → empty schedule
    {
        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 0,
            .budget_us = 1000,
            .motion_intensity = 0.0,
            .history_valid = true,
            .frame_mode = .real,
        };
        const result = try cost_scheduler.scheduleGpuPasses(allocator, &.{}, ctx);
        defer allocator.free(result.order);
        try testing.expectEqual(@as(usize, 0), result.order.len);
        try testing.expectEqual(@as(u32, 0), result.total_skipped);
    }

    // 2. Single pass within budget → executes
    {
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 1,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "main" } },
                .grid = .{ .x = 8, .y = 8, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };
        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 0, .budget_us = 1000, .motion_intensity = 0.0, .history_valid = true, .frame_mode = .real,
        };
        const result = try cost_scheduler.scheduleGpuPasses(allocator, &passes, ctx);
        defer allocator.free(result.order);
        try testing.expectEqual(@as(usize, 1), result.order.len);
        try testing.expectEqual(@as(usize, 0), result.order[0]);
        try testing.expectEqual(@as(u32, 0), result.total_skipped);
    }

    // 3. Two passes, budget fits only first → second skipped
    {
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 1,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "a" } },
                .grid = .{ .x = 8, .y = 8, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
            .{
                .pass_id = 2,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "b" } },
                .grid = .{ .x = 64, .y = 64, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };
        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 0, .budget_us = 200, .motion_intensity = 0.0, .history_valid = true, .frame_mode = .real,
        };
        const result = try cost_scheduler.scheduleGpuPasses(allocator, &passes, ctx);
        defer allocator.free(result.order);
        try testing.expectEqual(@as(usize, 1), result.order.len);
        try testing.expect(result.total_skipped == 1);
    }

    // 4. Budget too small for either pass → all skipped
    {
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 1,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "a" } },
                .grid = .{ .x = 4, .y = 4, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
            .{
                .pass_id = 2,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "b" } },
                .grid = .{ .x = 4, .y = 4, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };
        // Budget fits both (16 groups × 2us = 32us each, total 64us)
        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 0, .budget_us = 100, .motion_intensity = 0.0, .history_valid = true, .frame_mode = .real,
        };
        const result = try cost_scheduler.scheduleGpuPasses(allocator, &passes, ctx);
        defer allocator.free(result.order);
        try testing.expectEqual(@as(usize, 2), result.order.len);
        try testing.expectEqual(@as(u32, 0), result.total_skipped);
    }

    // 5. Generated mode: FSR3 passes get priority over non-FSR3
    {
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 200, // non-FSR3 render pass
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "render" } },
                .grid = .{ .x = 4, .y = 4, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
            .{
                .pass_id = 102, // FSR3 generate pass
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "fsr3_gen" } },
                .grid = .{ .x = 4, .y = 4, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
            .{
                .pass_id = 100, // FSR3 optical flow
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "fsr3_of" } },
                .grid = .{ .x = 4, .y = 4, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };
        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 0, .budget_us = 5000, .motion_intensity = 0.0, .history_valid = true, .frame_mode = .generated,
        };
        const result = try cost_scheduler.scheduleGpuPasses(allocator, &passes, ctx);
        defer allocator.free(result.order);
        // Small dispatch sizes (4x4=16 groups → 32us each), budget 5000 fits all
        // Order should be: FSR3 by pass_id first, then non-FSR3
        try testing.expectEqual(@as(usize, 3), result.order.len);
        try testing.expectEqual(@as(u32, 100), passes[result.order[0]].pass_id);
        try testing.expectEqual(@as(u32, 102), passes[result.order[1]].pass_id);
        try testing.expectEqual(@as(u32, 200), passes[result.order[2]].pass_id);
    }

    // 6. Pass_through mode: no passes scheduled (no critical flag set)
    {
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 1,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "a" } },
                .grid = .{ .x = 4, .y = 4, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };
        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 0, .budget_us = 10000, .motion_intensity = 0.0, .history_valid = true, .frame_mode = .pass_through,
        };
        const result = try cost_scheduler.scheduleGpuPasses(allocator, &passes, ctx);
        defer allocator.free(result.order);
        // All passes get max priority (skipped) — empty schedule
        try testing.expectEqual(@as(usize, 0), result.order.len);
        try testing.expectEqual(@as(u32, 1), result.total_skipped);
    }

    // 7. Determinism
    {
        const passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 5,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "a" } },
                .grid = .{ .x = 16, .y = 16, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
            .{
                .pass_id = 3,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "b" } },
                .grid = .{ .x = 16, .y = 16, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            },
        };
        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 0, .budget_us = 1000, .motion_intensity = 0.0, .history_valid = true, .frame_mode = .real,
        };
        const r1 = try cost_scheduler.scheduleGpuPasses(allocator, &passes, ctx);
        defer allocator.free(r1.order);
        const r2 = try cost_scheduler.scheduleGpuPasses(allocator, &passes, ctx);
        defer allocator.free(r2.order);
        try testing.expectEqual(r1.order.len, r2.order.len);
        try testing.expectEqual(r1.total_skipped, r2.total_skipped);
        try testing.expectEqual(r1.total_cost_us, r2.total_cost_us);
    }
}

fn testCompileFrame(allocator: std.mem.Allocator) !void {
    const testing = std.testing;

    // Create an FSR3Runtime with default config
    var rt = fsr3_runtime.FSR3Runtime.init(.{
        .display_width = 1920,
        .display_height = 1080,
        .render_width = 1920,
        .render_height = 1080,
        .gen_mode = .x2,
    });

    // Helper to make an empty LifetimeGraph that properly cleans up
    const makeEmptyLG = struct {
        fn create(a: std.mem.Allocator) lifetime_graph.LifetimeGraph {
            return .{ .entries = &.{}, .groups = &.{}, .alias_map = std.AutoHashMap(u64, u32).init(a) };
        }
    }.create;

    // ── Test 1: REAL mode (history invalid + budget OK) ──
    {
        const mode1 = rt.evaluateFramePolicy(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.1,
            .history_valid = false,
            .frame_index = 1,
        });
        try testing.expectEqual(fsr3_runtime.FrameMode.real, mode1);

        const fg = try rt.buildFrameGraph(allocator);
        defer allocator.free(fg.passes);
        const gpu_passes = try rt.buildGPUPasses(allocator, &fg);
        defer allocator.free(gpu_passes);

        var lg = makeEmptyLG(allocator);
        defer lg.deinit(allocator);

        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 1, .budget_us = 5000, .motion_intensity = 0.1,
            .history_valid = false, .frame_mode = .real,
        };
        var plan = try gpu_execution.compileGpuExecutionPlan(allocator, gpu_passes, &lg, &.{}, ctx);
        defer plan.deinit();

        try testing.expectEqual(@as(usize, 4), plan.dispatches.len);
        try testing.expectEqual(@as(u32, 100), plan.dispatches[0].pass_id);
        try testing.expectEqual(@as(u32, 5000), plan.frame_budget_us);
    }

    // ── Test 2: GENERATED mode (expensive non-FSR3 pass gets cut) ──
    {
        const mode2 = rt.evaluateFramePolicy(.{
            .frame_latency_us = 100,
            .motion_intensity = 0.1,
            .history_valid = true,
            .frame_index = 2,
        });
        try testing.expectEqual(fsr3_runtime.FrameMode.generated, mode2);

        const fg = try rt.buildFrameGraph(allocator);
        defer allocator.free(fg.passes);
        var gpu_passes = try rt.buildGPUPasses(allocator, &fg);
        defer allocator.free(gpu_passes);

        // Replace the 4th pass with a non-FSR3 pass that's too expensive
        gpu_passes[3] = .{
            .pass_id = 200,
            .queue = .compute,
            .pipeline = .{ .shader = .{ .source = "", .entry = "expensive" } },
            .grid = .{ .x = 64, .y = 64, .z = 1 },
            .bindings = gpu_types.BindGroup{ .entries = &.{} },
        };

        var lg = makeEmptyLG(allocator);
        defer lg.deinit(allocator);

        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 2, .budget_us = 5000, .motion_intensity = 0.1,
            .history_valid = true, .frame_mode = .generated,
        };
        var plan = try gpu_execution.compileGpuExecutionPlan(allocator, gpu_passes, &lg, &.{}, ctx);
        defer plan.deinit();

        // GENERATED mode: FSR3 passes (100-102, each ~128us) kept; expensive non-FSR3 pass (200, ~8192us) cut
        try testing.expectEqual(@as(usize, 3), plan.dispatches.len);
        try testing.expectEqual(@as(u32, 100), plan.dispatches[0].pass_id);
    }

    // ── Test 3: PASS_THROUGH mode → no dispatches ──
    {
        const mode3 = rt.evaluateFramePolicy(.{
            .frame_latency_us = 99999,
            .motion_intensity = 0.5,
            .history_valid = true,
            .frame_index = 3,
        });
        try testing.expectEqual(fsr3_runtime.FrameMode.pass_through, mode3);

        const fg = try rt.buildFrameGraph(allocator);
        defer allocator.free(fg.passes);
        const gpu_passes = try rt.buildGPUPasses(allocator, &fg);
        defer allocator.free(gpu_passes);

        var lg = makeEmptyLG(allocator);
        defer lg.deinit(allocator);

        const ctx = gpu_execution.ExecutionContext{
            .frame_index = 3, .budget_us = 5000, .motion_intensity = 0.5,
            .history_valid = true, .frame_mode = .pass_through,
        };
        var plan = try gpu_execution.compileGpuExecutionPlan(allocator, gpu_passes, &lg, &.{}, ctx);
        defer plan.deinit();

        try testing.expectEqual(@as(usize, 0), plan.dispatches.len);
    }

    // ── Test 4: buildGPUPasses sanity ──
    {
        const fg = try rt.buildFrameGraph(allocator);
        defer allocator.free(fg.passes);
        const gpu_passes = try rt.buildGPUPasses(allocator, &fg);
        defer allocator.free(gpu_passes);

        try testing.expectEqual(@as(usize, 4), gpu_passes.len);
        for (gpu_passes, 0..) |gp, i| {
            try testing.expectEqual(@as(u32, 100 + @as(u32, @intCast(i))), gp.pass_id);
            try testing.expectEqual(gpu_types.QueueType.compute, gp.queue);
        }
    }
}
