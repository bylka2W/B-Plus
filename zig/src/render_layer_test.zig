const std = @import("std");
const frame_graph = @import("frame_graph.zig");
const gpu_ir = @import("gpu_ir.zig");
const resource_system = @import("resource_system.zig");
const dx12 = @import("dx12_compute.zig");
const d3d = @import("d3d12_bindings.zig");
const rs_builder = @import("root_signature_builder.zig");
const fg_executor = @import("frame_graph_executor.zig");
const render_graph = @import("render_graph.zig");
const history_manager = @import("history_manager.zig");
const camera_jitter = @import("camera_jitter.zig");
const render_helpers = @import("render_helpers.zig");

pub fn main() !void {
    const W = 64;
    const H = 64;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // --- Init DX12 ---
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

    // --- Resource pool ---
    var pool = resource_system.ResourcePool.init(allocator, &ctx);
    defer pool.deinit();

    // --- History ---
    var history = history_manager.HistoryManager{};
    try history.initColor(&pool, W, H, .r32g32b32a32_float);
    defer history.deinit(&pool);
    history.valid = false;

    // --- Create scene color output + final output ---
    const scene_color_id = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32g32b32a32_float });
    const final_color_id = try pool.createTexture2D(.{ .width = W, .height = H, .format = .r32g32b32a32_float });

    // --- Executor ---
    var executor = fg_executor.FrameGraphGPUExecutor.init(allocator, &ctx, &pool);
    defer executor.deinit();

    // --- Run frames ---
    const num_frames: u32 = 4;
    for (0..num_frames) |frame| {
        const frame_u32 = @as(u32, @intCast(frame));
        const jitter = camera_jitter.getJitter(frame_u32);

        // Shader: scene write — jittered gradient pattern
        const scene_shader = try std.fmt.allocPrint(allocator,
            \\RWTexture2D<float4> ColorOut : register(u0);
            \\[numthreads(8, 8, 1)]
            \\void main(uint3 tid : SV_DispatchThreadID) {{
            \\    float2 uv = (float2(tid.xy) + 0.5) / float2({d}, {d});
            \\    ColorOut[tid.xy] = float4(uv, 0, 1);
            \\}}
        , .{ @as(f32, @floatFromInt(W)), @as(f32, @floatFromInt(H)) });
        defer allocator.free(scene_shader);

        // Shader: TAA resolve — blend current with history
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

        // Shader: sharpen (3x3 unsharp mask)
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

        // Bind layouts per pass
        const scene_layout = gpu_ir.BindLayout{ .slots = &.{
            gpu_ir.BindSlot{ .register = 0, .space = 0, .bind_type = .uav },
        } };
        const taa_layout = gpu_ir.BindLayout{ .slots = &.{
            gpu_ir.BindSlot{ .register = 0, .space = 0, .bind_type = .uav },
            gpu_ir.BindSlot{ .register = 0, .space = 0, .bind_type = .srv },
            gpu_ir.BindSlot{ .register = 1, .space = 0, .bind_type = .srv },
        } };
        const sharpen_layout = gpu_ir.BindLayout{ .slots = &.{
            gpu_ir.BindSlot{ .register = 0, .space = 0, .bind_type = .uav },
            gpu_ir.BindSlot{ .register = 0, .space = 0, .bind_type = .srv },
        } };

        const grid = render_helpers.dispatch2D(W, H);
        const history_tex = history.color.getPrevious();
        const current_tex = history.color.getCurrent();

        const gpu_passes = [_]frame_graph.GPUPassDesc{
            .{
                .pass_id = 0,
                .pipeline = .{ .shader = .{ .source = scene_shader, .entry = "main", .target = "cs_5_1" }, .layout = scene_layout },
                .grid = grid,
                .bindings = render_helpers.makeBindGroup(&.{
                    .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = scene_color_id },
                }),
            },
            .{
                .pass_id = 1,
                .pipeline = .{ .shader = .{ .source = taa_shader, .entry = "main", .target = "cs_5_1" }, .layout = taa_layout },
                .grid = grid,
                .bindings = render_helpers.makeBindGroup(&.{
                    .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = scene_color_id },
                    .{ .key = .{ .reg = 0, .space = 0, .kind = .srv }, .resource_id = current_tex.resource_id },
                    .{ .key = .{ .reg = 1, .space = 0, .kind = .srv }, .resource_id = history_tex.resource_id },
                }),
            },
            .{
                .pass_id = 2,
                .pipeline = .{ .shader = .{ .source = sharpen_shader, .entry = "main", .target = "cs_5_1" }, .layout = sharpen_layout },
                .grid = grid,
                .bindings = render_helpers.makeBindGroup(&.{
                    .{ .key = .{ .reg = 0, .space = 0, .kind = .uav }, .resource_id = final_color_id },
                    .{ .key = .{ .reg = 0, .space = 0, .kind = .srv }, .resource_id = scene_color_id },
                }),
            },
        };

        const frames = [_]frame_graph.Pass{
            .{ .id = 0, .name = "scene_write", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
            .{ .id = 1, .name = "taa_resolve", .deps = &.{0}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
            .{ .id = 2, .name = "sharpen", .deps = &.{1}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
        };

        var rg = render_graph.RenderGraph.init(allocator, &pool);
        var render_plan = try rg.compile(&frames, &gpu_passes, 10000);
        defer render_graph.RenderGraph.deinitPlan(allocator, &render_plan);

        try rg.allocateTransients(&render_plan);
        defer rg.releaseTransients(&render_plan);

        try executor.executeRenderPlanWithHistory(&render_plan, &history);

        std.debug.print("Frame {}: jitter=({d:.4},{d:.4}) history={} color_pass=0x{x}\n", .{
            frame, jitter.x, jitter.y, history.hasHistory(), scene_color_id,
        });
    }

    std.debug.print("All {} frames passed with auto-barriers + history flip\n", .{num_frames});
}
