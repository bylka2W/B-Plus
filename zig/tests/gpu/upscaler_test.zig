const std = @import("std");
const d3d = @import("../../src/render/d3d12_bindings.zig");
const dx12 = @import("../../src/render/dx12_compute.zig");

const IN_W: u32 = 8;
const IN_H: u32 = 8;
const OUT_W: u32 = 16;
const OUT_H: u32 = 16;

pub fn main() !void {
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // --- Root sig 1: UAV write (fill input texture) ---
    var rs1_params = [1]d3d.D3D12_ROOT_PARAMETER{
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = blk: {
                const r = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&[1]d3d.D3D12_DESCRIPTOR_RANGE{
                    .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
                }));
                break :blk r;
            } } },
            .ShaderVisibility = .ALL,
        },
    };
    var blob: ?*anyopaque = null;
    var err_blob: ?*anyopaque = null;
    var hr_ = ctx.D3D12SerializeRootSignature.?(&.{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs1_params)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 }, 1, &blob, &err_blob);
    if (hr_ < 0) return error.RS1Failed;
    var rs1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs1);
    if (hr_ < 0) return error.RS1Failed;
    d3d.release(blob);

    // --- Root sig 2: SRV(t0)+sampler(s0)+UAV(u0) for upsampling ---
    var rs2_params = [2]d3d.D3D12_ROOT_PARAMETER{
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 2, .pDescriptorRanges = blk: {
                const r = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&[2]d3d.D3D12_DESCRIPTOR_RANGE{
                    .{ .RangeType = .SRV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
                    .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 1 },
                }));
                break :blk r;
            } } },
            .ShaderVisibility = .ALL,
        },
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = blk: {
                const r = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&[1]d3d.D3D12_DESCRIPTOR_RANGE{
                    .{ .RangeType = .SAMPLER, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
                }));
                break :blk r;
            } } },
            .ShaderVisibility = .ALL,
        },
    };
    hr_ = ctx.D3D12SerializeRootSignature.?(&.{ .NumParameters = 2, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs2_params)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 }, 1, &blob, &err_blob);
    if (hr_ < 0) return error.RS2Failed;
    var rs2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs2);
    if (hr_ < 0) return error.RS2Failed;
    d3d.release(blob);

    // --- PSO 1: Fill input texture with pattern ---
    const fill_shader = \\RWTexture2D<float> tex : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    tex[tid.xy] = float(tid.x + tid.y * 8);
        \\}
    ;
    const fill_code = try dx12.compileShaderSource(fill_shader);
    var pso1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &.{ .pRootSignature = rs1, .CS = .{ .pShaderBytecode = fill_code.ptr, .BytecodeLength = fill_code.len } }, &d3d.IID_ID3D12PipelineState, &pso1);
    if (hr_ < 0) return error.PSO1Failed;
    errdefer d3d.release(pso1);

    // --- PSO 2: Bilinear upsample ---
    const ups_shader = \\Texture2D<float> inputTex : register(t0);
        \\SamplerState samp : register(s0);
        \\RWTexture2D<float> outputTex : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    uint w, h;
        \\    outputTex.GetDimensions(w, h);
        \\    float2 uv = (float2(tid.xy) + 0.5) / float2(w, h);
        \\    outputTex[tid.xy] = inputTex.SampleLevel(samp, uv, 0);
        \\}
    ;
    const ups_code = try dx12.compileShaderSource(ups_shader);
    var pso2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &.{ .pRootSignature = rs2, .CS = .{ .pShaderBytecode = ups_code.ptr, .BytecodeLength = ups_code.len } }, &d3d.IID_ID3D12PipelineState, &pso2);
    if (hr_ < 0) return error.PSO2Failed;
    errdefer d3d.release(pso2);

    // --- Resources ---
    const in_tex = try ctx.createTexture2D(IN_W, IN_H, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(in_tex);

    const out_tex = try ctx.createTexture2D(OUT_W, OUT_H, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(out_tex);

    // Readback buffer for output
    const readback = try ctx.createBuffer(try ctx.getTextureFootprint(OUT_W, OUT_H, .R32_FLOAT), .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    errdefer d3d.release(readback);

    var row_pitch: u32 = 0;

    // --- Descriptors ---
    const cmd = ctx.cmd_list;

    // Write pass: input texture UAV at index 0
    ctx.createUAVViewTexture(in_tex, &ctx.createUAVTexture2DDesc(0), ctx.getUAVCPUHandle(0));

    // Upsample pass: SRV(in) at index 0, UAV(out) at index 1
    ctx.createSRV(in_tex, &ctx.createSRVTexture2DDesc(1), ctx.getUAVCPUHandle(0));
    ctx.createUAVViewTexture(out_tex, &ctx.createUAVTexture2DDesc(0), ctx.getUAVCPUHandle(1));

    // Sampler at index 0
    ctx.createSampler(&ctx.createSamplerDesc(), ctx.getSamplerCPUHandle(0));

    // ===== Pass 1: Fill input texture =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso1);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs1);
        var heaps1 = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps1);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 1, 1, 1);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CF1;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 1: input texture filled\n", .{});
    }

    // Barrier: input UNORDERED_ACCESS -> NON_PIXEL_SHADER_RESOURCE
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        dx12.ComputeContext.bufferBarrier(cmd.?, in_tex, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CFB;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Barrier done\n", .{});
    }

    // ===== Pass 2: Upsample =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso2);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs2);
        var heaps2 = [_]?*anyopaque{ ctx.uav_heap, ctx.sampler_heap };
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 2, &heaps2);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 1, ctx.getSamplerGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, OUT_W / 8, OUT_H / 8, 1);

        // Barrier output: UNORDERED_ACCESS -> COPY_SOURCE
        dx12.ComputeContext.bufferBarrier(cmd.?, out_tex, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        row_pitch = ctx.copyTextureToBuffer(readback, out_tex, OUT_W, OUT_H, .R32_FLOAT);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CF2;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 2: upsample done\n", .{});
    }

    // Verify
    const ptr = try dx12.ComputeContext.mapBuffer(readback);
    defer dx12.ComputeContext.unmapBuffer(readback);
    const data: [*]f32 = @ptrCast(@alignCast(ptr));

    const row_floats = row_pitch / 4;
    std.debug.print("RowPitch = {} bytes, {} floats per row\n", .{ row_pitch, row_floats });

    var pass: bool = true;
    // Sanity checks: bilinear upscale 8x8 → 16x16, values 0..63
    const checks = [_]struct { ox: u32, oy: u32, expected: f32, tol: f32 }{
        .{ .ox = 0, .oy = 0, .expected = 0, .tol = 2.0 },
        .{ .ox = 15, .oy = 15, .expected = 63, .tol = 2.0 },
        .{ .ox = 8, .oy = 0, .expected = 3.75, .tol = 0.5 },
        .{ .ox = 0, .oy = 8, .expected = 30.75, .tol = 2.0 },
    };
    for (checks) |c| {
        const val = data[c.oy * row_floats + c.ox];
        const diff = @abs(val - c.expected);
        if (diff > c.tol) {
            std.debug.print("FAIL[{}x{}]: got {} expected {} (diff={})\n", .{ c.ox, c.oy, val, c.expected, diff });
            pass = false;
        } else {
            std.debug.print("OK[{}x{}]: got {} expected {}\n", .{ c.ox, c.oy, val, c.expected });
        }
    }
    if (pass) std.debug.print("PASS: Upscaler verified ({d}x{d} -> {d}x{d})\n", .{ IN_W, IN_H, OUT_W, OUT_H });

    d3d.release(rs1);
    d3d.release(rs2);
    d3d.release(pso1);
    d3d.release(pso2);
}
