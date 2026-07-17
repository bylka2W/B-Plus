const std = @import("std");
const d3d = @import("../../src/render/d3d12_bindings.zig");
const dx12 = @import("../../src/render/dx12_compute.zig");

pub fn main() !void {
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const W: u32 = 8;
    const H: u32 = 8;

    // --- Root sig 1: UAV only (fill) ---
    var rs1_ranges = [1]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
    };
    var rs1_params = [1]d3d.D3D12_ROOT_PARAMETER{
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs1_ranges)) } },
            .ShaderVisibility = .ALL,
        },
    };
    var rs1_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{
        .NumParameters = 1,
        .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs1_params)),
        .NumStaticSamplers = 0,
        .pStaticSamplers = null,
        .Flags = 0,
    };
    var blob: ?*anyopaque = null;
    var err_blob: ?*anyopaque = null;
    var hr_ = ctx.D3D12SerializeRootSignature.?(&rs1_desc, 1, &blob, &err_blob);
    if (hr_ < 0) return error.RS1Failed;
    var rs1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs1);
    if (hr_ < 0) return error.RS1Failed;
    d3d.release(blob);

    // --- Root sig 2: SRV + UAV + SAMPLER (sharpen) ---
    var rs2_ranges = [2]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .SRV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 1 },
    };
    var rs2_samp = [1]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .SAMPLER, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
    };
    var rs2_params = [2]d3d.D3D12_ROOT_PARAMETER{
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 2, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs2_ranges)) } },
            .ShaderVisibility = .ALL,
        },
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs2_samp)) } },
            .ShaderVisibility = .ALL,
        },
    };
    var rs2_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{
        .NumParameters = 2,
        .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs2_params)),
        .NumStaticSamplers = 0,
        .pStaticSamplers = null,
        .Flags = 0,
    };
    hr_ = ctx.D3D12SerializeRootSignature.?(&rs2_desc, 1, &blob, &err_blob);
    if (hr_ < 0) { if (err_blob) |eb| d3d.release(eb); return error.RS2Failed; }
    var rs2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs2);
    if (hr_ < 0) return error.RS2Failed;
    d3d.release(blob);

    // --- PSO 1: Fill with step pattern ---
    const fill_shader =
        \\RWTexture2D<float> tex : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    tex[tid.xy] = tid.x < 4 ? 0.0 : 100.0;
        \\}
    ;
    const fill_code = try dx12.compileShaderSource(fill_shader);
    var pso1_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{
        .pRootSignature = rs1,
        .CS = .{ .pShaderBytecode = fill_code.ptr, .BytecodeLength = fill_code.len },
    };
    var pso1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso1_desc, &d3d.IID_ID3D12PipelineState, &pso1);
    if (hr_ < 0) return error.PSO1Failed;
    defer d3d.release(pso1);

    // --- PSO 2: 3x3 unsharp mask sharpen ---
    const sharpen_shader =
        \\Texture2D<float> inputTex : register(t0);
        \\SamplerState samp : register(s0);
        \\RWTexture2D<float> outputTex : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    uint w, h;
        \\    outputTex.GetDimensions(w, h);
        \\    int2 uv = int2(tid.xy);
        \\    float c = inputTex.Load(int3(uv, 0));
        \\    float sum = 0;
        \\    for (int dy = -1; dy <= 1; dy++) {
        \\        for (int dx = -1; dx <= 1; dx++) {
        \\            sum += inputTex.Load(int3(uv + int2(dx, dy), 0));
        \\        }
        \\    }
        \\    float blur = sum / 9.0;
        \\    float diff = c - blur;
        \\    outputTex[tid.xy] = c + diff * 2.0;
        \\}
    ;
    const sharpen_code = try dx12.compileShaderSource(sharpen_shader);
    var pso2_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{
        .pRootSignature = rs2,
        .CS = .{ .pShaderBytecode = sharpen_code.ptr, .BytecodeLength = sharpen_code.len },
    };
    var pso2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso2_desc, &d3d.IID_ID3D12PipelineState, &pso2);
    if (hr_ < 0) return error.PSO2Failed;
    defer d3d.release(pso2);

    // --- Sampler (point filter for Load) ---
    var samp_desc = ctx.createSamplerDesc();
    samp_desc.Filter = .MIN_MAG_MIP_POINT;
    ctx.createSampler(&samp_desc, ctx.getSamplerCPUHandle(0));

    // --- Resources ---
    const texture = try ctx.createTexture2D(W, H, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(texture);

    const readback = try ctx.createBuffer(try ctx.getTextureFootprint(W, H, .R32_FLOAT), .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    defer d3d.release(readback);

    const cmd = ctx.cmd_list;

    // --- Descriptors ---
    // heap[0] = texture UAV (fill), then texture SRV (sharpen)
    // heap[1] = output UAV for sharpen (we reuse as sharpen output for same texture, but need separate)
    // Actually for in-place sharpen, we SRV read + UAV write to same texture? That's illegal.
    // We need separate textures for input and output.

    // Let's create output texture
    const tex_out = try ctx.createTexture2D(W, H, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_out);

    // Fill pass: texture UAV at heap[0]
    const tex_uav = ctx.createUAVTexture2DDesc(0);
    ctx.createUAVViewTexture(texture, &tex_uav, ctx.getUAVCPUHandle(0));

    // Sharpen pass: texture SRV at heap[0], tex_out UAV at heap[1]
    const srv_desc = ctx.createSRVTexture2DDesc(1);
    ctx.createSRV(texture, &srv_desc, ctx.getUAVCPUHandle(0));

    const out_uav = ctx.createUAVTexture2DDesc(0);
    ctx.createUAVViewTexture(tex_out, &out_uav, ctx.getUAVCPUHandle(1));

    // ===== PASS 1: Fill texture with step pattern =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso1);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs1);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 1, 1, 1);

        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseFailed1;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 1: fill step pattern complete\n", .{});
    }

    // Barrier: texture UNORDERED_ACCESS -> NON_PIXEL_SHADER_RESOURCE (for SRV)
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        dx12.ComputeContext.bufferBarrier(cmd.?, texture, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseBarrier1;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Barrier done\n", .{});
    }

    // ===== PASS 2: Apply sharpen =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso2);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs2);
        var heaps = [_]?*anyopaque{ ctx.uav_heap, ctx.sampler_heap };
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 2, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 1, ctx.getSamplerGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 1, 1, 1);

        // Barrier: tex_out UNORDERED_ACCESS -> COPY_SOURCE
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_out, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);

        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseFailed2;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 2: sharpen complete\n", .{});
    }

    // Barrier: tex_out COPY_SOURCE -> COPY_DEST? No, tex_out is DEFAULT heap, need COPY_SOURCE for CopyTextureRegion
    // Actually tex_out is in DEFAULT heap with UNORDERED_ACCESS initial state. After DRAW we transition to COPY_SOURCE.
    // But the barrier was inside the previous command list. Let's do CopyTextureRegion in a new command list.

    // ===== PASS 3: CopyTextureRegion tex_out -> readback =====
    var row_pitch: u32 = undefined;
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);

        row_pitch = ctx.copyTextureToBuffer(readback, tex_out, W, H, .R32_FLOAT);

        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseCopy;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 3: CopyTextureRegion complete (RowPitch={})\n", .{row_pitch});
    }

    // Verify
    const ptr = try dx12.ComputeContext.mapBuffer(readback);
    defer dx12.ComputeContext.unmapBuffer(readback);
    const data: [*]f32 = @ptrCast(@alignCast(ptr));

    const row_floats = row_pitch / 4;

    std.debug.print("\nVerification:\n", .{});
    for (0..H) |y| {
        std.debug.print("  row {}: ", .{y});
        for (0..W) |x| {
            std.debug.print("{d:6.1} ", .{data[y * row_floats + x]});
        }
        std.debug.print("\n", .{});
    }

    var pass: bool = true;
    // Check: at edge (x=3, y=3), sharpened should have overshoot
    // Position (3,3): originally 0.0, should go negative (undershoot)
    // Position (4,3): originally 100.0, should go >100 (overshoot)
    const v3 = data[3 * row_floats + 3];
    const v4 = data[3 * row_floats + 4];
    std.debug.print("\nEdge check: [3,3]={d:.1} (expect <0), [4,3]={d:.1} (expect >100)\n", .{ v3, v4 });
    if (v3 >= 0) { std.debug.print("FAIL: no undershoot at edge\n", .{}); pass = false; }
    if (v4 <= 100) { std.debug.print("FAIL: no overshoot at edge\n", .{}); pass = false; }

    // Check: flat area before edge should be near 0
    const v0 = data[3 * row_floats + 0];
    const v1 = data[3 * row_floats + 1];
    const v2 = data[3 * row_floats + 2];
    std.debug.print("Flat left: [3,0]={d:.1} [3,1]={d:.1} [3,2]={d:.1} (expect ~0)\n", .{ v0, v1, v2 });
    if (@abs(v0) > 5 or @abs(v1) > 5 or @abs(v2) > 5) {
        std.debug.print("FAIL: flat area disturbed\n", .{});
        pass = false;
    }

    // Check: flat area after edge should be near 100 (exclude boundary pixel x=7 where 3x3 reads OOB)
    const v5 = data[3 * row_floats + 5];
    const v6 = data[3 * row_floats + 6];
    std.debug.print("Flat right: [3,5]={d:.1} [3,6]={d:.1} (expect ~100)\n", .{ v5, v6 });
    if (@abs(v5 - 100) > 5 or @abs(v6 - 100) > 5) {
        std.debug.print("FAIL: flat area disturbed\n", .{});
        pass = false;
    }

    if (pass) {
        std.debug.print("\nPASS: Adaptive sharpening verified\n", .{});
    }

    d3d.release(rs1);
    d3d.release(rs2);
}
