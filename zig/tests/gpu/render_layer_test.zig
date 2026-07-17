const std = @import("std");
const frame_graph = @import("../../src/render/frame_graph.zig");
const gpu_types = @import("../../src/compiler/backend/gpu/gpu_types.zig");
const resource_system = @import("../../src/render/resource_system.zig");
const dx12 = @import("../../src/render/dx12_compute.zig");
const d3d = @import("../../src/render/d3d12_bindings.zig");
const rs_builder = @import("../../src/render/root_signature_builder.zig");
const fg_executor = @import("../../src/render/frame_graph_executor.zig");
const render_graph = @import("../../src/render/render_graph.zig");
const history_manager = @import("../../src/render/history_manager.zig");
const camera_jitter = @import("../../src/render/camera_jitter.zig");
const render_helpers = @import("../../src/render/render_helpers.zig");
const frame_runtime = @import("../../src/render/frame_runtime.zig");
const gpu_scheduler = @import("../../src/runtime/gpu_scheduler.zig");
const compiled_graph = @import("../../src/render/compiled_graph.zig");

pub fn main() !void {
    const W: u32 = 64;
    const H: u32 = 64;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var ctx = dx12.ComputeContext{
        .device = null, .queue = null, .cmd_allocator = null, .cmd_list = null,
        .fence = null, .fence_value = 0, .event = 0,
        .uav_heap = null, .uav_heap_increment = 0,
        .sampler_heap = null, .sampler_heap_increment = 0,
        .root_sig = null, .pso = null, .d3d12_module = null,
        .D3D12CreateDevice = null, .D3D12SerializeRootSignature = null,
        .D3D12SerializeVersionedRootSignature = null, .D3D12GetDebugInterface = null,
    };
    try ctx.init();
    defer ctx.deinit();

    var runtime = try frame_runtime.FrameRuntime.init(allocator, &ctx);
    defer { runtime.drain(); runtime.deinit(); }

    var pool = resource_system.ResourcePool.init(allocator, &ctx);
    defer pool.deinit();

    var history = history_manager.HistoryManager{};
    try history.initColor(&pool, W, H, .r32g32b32a32_float);
    defer history.deinit(&pool);
    history.valid = false;

    const scene_color_id = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32g32b32a32_float });
    const final_color_id = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32g32b32a32_float });
    const motion_velocity_id = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32g32b32a32_float });

    var executor = fg_executor.FrameGraphGPUExecutor.init(allocator, &ctx, &pool);
    defer executor.deinit();

    const num_frames: u32 = 4;
    const grid = render_helpers.dispatch2D(W, H);

    const scene_shader =
        \\RWTexture2D<float4> ColorOut : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    float2 uv = (float2(tid.xy) + 0.5) / float2(64, 64);
        \\    ColorOut[tid.xy] = float4(uv, 0, 1);
        \\}
    ;

    const motion_shader =
        \\RWTexture2D<float4> MotionOut : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    MotionOut[tid.xy] = float4(0, 0, 0, 0);
        \\}
    ;

    const taa_shader =
        \\RWTexture2D<float4> Result : register(u0);
        \\Texture2D<float4> Current : register(t0);
        \\Texture2D<float4> History : register(t1);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    float4 cur = Current[tid.xy];
        \\    float4 hist = History[tid.xy];
        \\    float blend = 0.2;
        \\    Result[tid.xy] = lerp(cur, hist, blend);
        \\}
    ;

    const sharpen_shader =
        \\RWTexture2D<float4> Result : register(u0);
        \\Texture2D<float4> Input : register(t0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    float4 c = Input[tid.xy];
        \\    float4 sum = Input[int2(tid.x-1,tid.y-1)] + Input[int2(tid.x,tid.y-1)] + Input[int2(tid.x+1,tid.y-1)]
        \\               + Input[int2(tid.x-1,tid.y)]   + Input[int2(tid.x+1,tid.y)]
        \\               + Input[int2(tid.x-1,tid.y+1)] + Input[int2(tid.x,tid.y+1)] + Input[int2(tid.x+1,tid.y+1)];
        \\    float4 blurred = sum / 8.0;
        \\    Result[tid.xy] = saturate(c + (c - blurred) * 0.5);
        \\}
    ;

    const scene_layout = gpu_types.BindLayout{ .slots = &.{
        gpu_types.BindSlot{ .register = 0, .space = 0, .bind_type = .uav },
    } };
    const motion_layout = gpu_types.BindLayout{ .slots = &.{
        gpu_types.BindSlot{ .register = 0, .space = 0, .bind_type = .uav },
    } };
    const taa_layout = gpu_types.BindLayout{ .slots = &.{
        gpu_types.BindSlot{ .register = 0, .space = 0, .bind_type = .uav },
        gpu_types.BindSlot{ .register = 0, .space = 0, .bind_type = .srv },
        gpu_types.BindSlot{ .register = 1, .space = 0, .bind_type = .srv },
    } };
    const sharpen_layout = gpu_types.BindLayout{ .slots = &.{
        gpu_types.BindSlot{ .register = 0, .space = 0, .bind_type = .uav },
        gpu_types.BindSlot{ .register = 0, .space = 0, .bind_type = .srv },
    } };

    // Build graph topology once (static for all frames)
    const gpu_passes = [_]frame_graph.GPUPassDesc{
        .{
            .pass_id = 0,
            .queue = .compute,
            .pipeline = .{ .shader = .{ .source = scene_shader, .entry = "main", .target = "cs_5_1" }, .layout = scene_layout },
            .grid = grid,
            .bindings = render_helpers.makeBindGroup(&.{
                .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = scene_color_id },
            }),
        },
        .{
            .pass_id = 1,
            .queue = .compute,
            .pipeline = .{ .shader = .{ .source = motion_shader, .entry = "main", .target = "cs_5_1" }, .layout = motion_layout },
            .grid = grid,
            .bindings = render_helpers.makeBindGroup(&.{
                .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = motion_velocity_id },
            }),
        },
        .{
            .pass_id = 2,
            .queue = .compute,
            .pipeline = .{ .shader = .{ .source = taa_shader, .entry = "main", .target = "cs_5_1" }, .layout = taa_layout },
            .grid = grid,
            .bindings = render_helpers.makeBindGroup(&.{
                .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = scene_color_id },
                .{ .key = .{ .reg = 0, .space = 0, .kind = .srv }, .resource_id = history.color.textures[0] },
                .{ .key = .{ .reg = 1, .space = 0, .kind = .srv }, .resource_id = history.color.textures[1] },
            }),
        },
        .{
            .pass_id = 3,
            .queue = .compute,
            .pipeline = .{ .shader = .{ .source = sharpen_shader, .entry = "main", .target = "cs_5_1" }, .layout = sharpen_layout },
            .grid = grid,
            .bindings = render_helpers.makeBindGroup(&.{
                .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = final_color_id },
                .{ .key = .{ .reg = 0, .space = 0, .kind = .srv }, .resource_id = scene_color_id },
            }),
        },
    };

    const frames = [_]frame_graph.Pass{
        .{ .id = 0, .name = "scene",   .deps = &.{},       .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
        .{ .id = 1, .name = "motion",  .deps = &.{},       .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
        .{ .id = 2, .name = "taa",     .deps = &.{ 0, 1 }, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
        .{ .id = 3, .name = "sharpen", .deps = &.{ 2 },    .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
    };

    // Compile graph once (topology + PSO/RS + descriptor layout + bind slot map)
    var rg = render_graph.RenderGraph.init(allocator, &pool);
    var plan = try rg.compile(&frames, &gpu_passes, 10000);
    defer render_graph.RenderGraph.deinitPlan(allocator, &plan);

    try rg.allocateTransients(&plan);
    defer rg.releaseTransients(&plan);

    var scheduler = gpu_scheduler.GPUScheduler.init(allocator);
    var schedule = try scheduler.build(&plan);
    defer gpu_scheduler.GPUScheduler.deinitScheduledFrame(allocator, &schedule);

    var cg = try executor.compileGraph(&plan, &schedule);
    defer cg.deinit();

    // Per-frame loop: no graph, no plan, no DAG — only FrameInputs
    for (0..num_frames) |frame| {
        history.beginFrame();

        const inputs = compiled_graph.FrameInputs{
            .resources = &[_]gpu_types.ResourceId{
                scene_color_id,                            // slot 0
                motion_velocity_id,                        // slot 1
                history.color.textures[0],                 // slot 2
                history.color.textures[1],                 // slot 3
                final_color_id,                            // slot 4
            },
        };

        try executor.executeCompiledFrame(&cg, &inputs, &runtime);

        history.flip();

        std.debug.print("Frame {}: history={}\n", .{ frame, history.hasHistory() });
    }

    runtime.drain();
    std.debug.print("All {} frames passed: compileGraph+FrameInputs, no RenderPlan in runtime\n", .{num_frames});
}
