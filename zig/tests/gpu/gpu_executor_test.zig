const std = @import("std");
const frame_graph = @import("../../src/render/frame_graph.zig");
const gpu_types = @import("../../src/compiler/backend/gpu/gpu_types.zig");
const resource_system = @import("../../src/render/resource_system.zig");
const frame_graph_executor = @import("../../src/render/frame_graph_executor.zig");
const dx12 = @import("../../src/render/dx12_compute.zig");
const d3d = @import("../../src/render/d3d12_bindings.zig");

const W = 8;
const H = 8;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // --- 1. DX12 init ---
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // --- 2. Resource Pool ---
    var pool = resource_system.ResourcePool.init(allocator, &ctx);
    defer pool.deinit();

    // --- 3. Create resources ---
    const tex_a = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32_float });
    const tex_b = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32_float });
    const tex_c = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32_float });

    // --- 4. Test 1: UAV-only passes (SRV + UAV mixed) ---
    std.debug.print("=== Test 1: UAV-only passes ===\n", .{});

    var passes1 = [_]frame_graph.Pass{
        .{ .id = 0, .name = "fill_a", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 10, .critical = true },
        .{ .id = 1, .name = "fill_b", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 10, .critical = true },
        .{ .id = 2, .name = "add", .deps = &.{ 0, 1 }, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 20, .critical = true },
    };
    var fg1 = frame_graph.FrameGraph.init(&passes1);
    var plan1 = try fg1.compile(allocator, 100);
    defer frame_graph.FrameGraph.deinitPlan(allocator, &plan1);

    const fill_shader =
        \\RWTexture2D<float> buf : register(u0);
        \\[numthreads(8,8,1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    buf[tid.xy] = float(tid.x + tid.y * 8);
        \\}
    ;
    const add_shader =
        \\RWTexture2D<float> a : register(u0);
        \\RWTexture2D<float> b : register(u1);
        \\RWTexture2D<float> c : register(u2);
        \\[numthreads(8,8,1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    c[tid.xy] = a[tid.xy] + b[tid.xy];
        \\}
    ;

    var gpu_passes1 = [_]frame_graph.GPUPassDesc{
        .{
            .pass_id = 0,
            .pipeline = .{ .shader = .{ .source = fill_shader }, .layout = .{ .slots = &.{.{ .register = 0, .space = 0, .bind_type = .uav }} } },
            .grid = .{ .x = 1, .y = 1 },
            .bindings = .{ .entries = &.{.{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = tex_a }} },
        },
        .{
            .pass_id = 1,
            .pipeline = .{ .shader = .{ .source = fill_shader }, .layout = .{ .slots = &.{.{ .register = 0, .space = 0, .bind_type = .uav }} } },
            .grid = .{ .x = 1, .y = 1 },
            .bindings = .{ .entries = &.{.{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = tex_b }} },
        },
        .{
            .pass_id = 2,
            .pipeline = .{ .shader = .{ .source = add_shader }, .layout = .{ .slots = &.{
                .{ .register = 0, .space = 0, .bind_type = .uav },
                .{ .register = 1, .space = 0, .bind_type = .uav },
                .{ .register = 2, .space = 0, .bind_type = .uav },
            } } },
            .grid = .{ .x = 1, .y = 1 },
            .bindings = .{ .entries = &.{
                .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = tex_a },
                .{ .key = .{ .reg = 1, .space = 0, .kind = .uav }, .resource_id = tex_b },
                .{ .key = .{ .reg = 2, .space = 0, .kind = .uav }, .resource_id = tex_c },
            } },
        },
    };

    var exec1 = frame_graph_executor.FrameGraphGPUExecutor.init(allocator, &ctx, &pool);
    defer exec1.deinit();
    try exec1.execute(&plan1, &gpu_passes1);
    std.debug.print("Test 1 PASS: 3 UAV-only passes\n", .{});

    // --- 5. Test 2: SRV+UAV mixed pass ---
    std.debug.print("\n=== Test 2: SRV+UAV mixed pass ===\n", .{});

    var passes2 = [_]frame_graph.Pass{
        .{ .id = 0, .name = "srv_uav", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 10, .critical = true },
    };
    var fg2 = frame_graph.FrameGraph.init(&passes2);
    var plan2 = try fg2.compile(allocator, 100);
    defer frame_graph.FrameGraph.deinitPlan(allocator, &plan2);

    const srv_uav_shader =
        \\Texture2D<float> src : register(t0);
        \\RWTexture2D<float> dst : register(u0);
        \\SamplerState smp : register(s0);
        \\[numthreads(8,8,1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    uint2 os; dst.GetDimensions(os.x, os.y);
        \\    float2 uv = (float2(tid.xy) + 0.5) / float2(os);
        \\    dst[tid.xy] = src.SampleLevel(smp, uv, 0);
        \\}
    ;

    var gpu_passes2 = [_]frame_graph.GPUPassDesc{
        .{
            .pass_id = 0,
            .pipeline = .{ .shader = .{ .source = srv_uav_shader }, .layout = .{ .slots = &.{
                .{ .register = 0, .space = 0, .bind_type = .srv },
                .{ .register = 0, .space = 0, .bind_type = .uav },
            } } },
            .grid = .{ .x = 1, .y = 1 },
            .bindings = .{ .entries = &.{
                .{ .key = .{ .reg = 0, .space = 0, .kind = .srv }, .resource_id = tex_a },
                .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = tex_c },
            } },
            .barriers_before = &.{
                .{ .resource_id = tex_a, .state_after = .non_pixel_shader_resource },
                .{ .resource_id = tex_c, .state_after = .unordered_access },
            },
        },
    };

    var exec2 = frame_graph_executor.FrameGraphGPUExecutor.init(allocator, &ctx, &pool);
    defer exec2.deinit();
    try exec2.execute(&plan2, &gpu_passes2);
    std.debug.print("Test 2 PASS: SRV+UAV mixed pass\n", .{});

    std.debug.print("\nALL TESTS PASSED\n", .{});
}
