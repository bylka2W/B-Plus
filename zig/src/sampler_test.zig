const std = @import("std");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

pub fn main() !void {
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const num_elements: u32 = 64;
    const tex_width: u32 = 64;
    const tex_height: u32 = 1;

    // --- Root Signature 1: write pass (UAV only) ---
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
    if (hr_ < 0) { if (err_blob) |eb| { if (@intFromPtr(d3d.getBlobVtbl(eb).GetBufferPointer(eb)) != 0) std.debug.print("RS1 err: {s}\n", .{@as([*:0]u8, @ptrCast(d3d.getBlobVtbl(eb).GetBufferPointer(eb)))}); } return error.RS1Failed; }

    var rs1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs1);
    if (hr_ < 0) return error.RS1Failed;
    d3d.release(blob);

    // --- Root Signature 2: sample pass (SRV t0 + sampler s0 + UAV u0) ---
    var rs2_ranges = [2]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .SRV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 1 },
    };
    var rs2_samp_range = [1]d3d.D3D12_DESCRIPTOR_RANGE{
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
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs2_samp_range)) } },
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
    if (hr_ < 0) { if (err_blob) |eb| { if (@intFromPtr(d3d.getBlobVtbl(eb).GetBufferPointer(eb)) != 0) std.debug.print("RS2 err: {s}\n", .{@as([*:0]u8, @ptrCast(d3d.getBlobVtbl(eb).GetBufferPointer(eb)))}); } return error.RS2Failed; }

    var rs2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs2);
    if (hr_ < 0) return error.RS2Failed;
    d3d.release(blob);

    // --- PSO 1: Write constant value to RWTexture2D ---
    const write_shader =
        \\RWTexture2D<float> tex : register(u0);
        \\[numthreads(64, 1, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    tex[uint2(tid.x, 0)] = float(tid.x * 2 + 100);
        \\}
    ;
    const write_code = try dx12.compileShaderSource(write_shader);
    var pso1_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{
        .pRootSignature = rs1,
        .CS = .{ .pShaderBytecode = write_code.ptr, .BytecodeLength = write_code.len },
    };
    var pso1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso1_desc, &d3d.IID_ID3D12PipelineState, &pso1);
    if (hr_ < 0) return error.PSO1Failed;
    errdefer d3d.release(pso1);

    // --- PSO 2: Sample SRV texture, write to buffer ---
    const sample_shader =
        \\Texture2D<float> tex : register(t0);
        \\SamplerState samp : register(s0);
        \\RWBuffer<float> buf : register(u0);
        \\[numthreads(64, 1, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    float v = tex.SampleLevel(samp, float2((float(tid.x) + 0.5) / 64.0, 0.5), 0);
        \\    buf[tid.x] = v;
        \\}
    ;
    const sample_code = try dx12.compileShaderSource(sample_shader);
    var pso2_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{
        .pRootSignature = rs2,
        .CS = .{ .pShaderBytecode = sample_code.ptr, .BytecodeLength = sample_code.len },
    };
    var pso2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso2_desc, &d3d.IID_ID3D12PipelineState, &pso2);
    if (hr_ < 0) return error.PSO2Failed;
    errdefer d3d.release(pso2);

    // --- Resources ---
    // Texture as UAV (for writing), then SRV (for sampling)
    const texture = try ctx.createTexture2D(tex_width, tex_height, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(texture);

    // Output buffer (UAV + readback)
    const buf_size: u64 = num_elements * 4;
    const uav_buf = try ctx.createBuffer(buf_size, .DEFAULT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(uav_buf);

    const readback = try ctx.createBuffer(buf_size, .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    errdefer d3d.release(readback);

    // --- Descriptors ---
    const cmd = ctx.cmd_list;

    // Write Pass: UAV at heap index 0 (texture UAV)
    const tex_uav_desc = ctx.createUAVTexture2DDesc(0);
    ctx.createUAVViewTexture(texture, &tex_uav_desc, ctx.getUAVCPUHandle(0));

    // Sample Pass: SRV at heap index 0, UAV at heap index 1
    const srv_desc = ctx.createSRVTexture2DDesc(1);
    ctx.createSRV(texture, &srv_desc, ctx.getUAVCPUHandle(0));

    const buf_uav_desc = dx12.ComputeContext.createUAVDesc(null, num_elements);
    ctx.createUAVView(uav_buf, &buf_uav_desc, ctx.getUAVCPUHandle(1));

    // Sampler at sampler heap index 0
    const samp_desc = ctx.createSamplerDesc();
    ctx.createSampler(&samp_desc, ctx.getSamplerCPUHandle(0));

    // ===== PASS 1: Write to texture =====
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
        std.debug.print("Pass 1 done (texture write)\n", .{});
    }

    // Barrier: texture UNORDERED_ACCESS -> NON_PIXEL_SHADER_RESOURCE (for SRV in compute)
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        dx12.ComputeContext.bufferBarrier(cmd.?, texture, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseBarrier;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Barrier done\n", .{});
    }

    // ===== PASS 2: Sample texture, write to buffer =====
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

        // Barrier buffer: UNORDERED_ACCESS -> COPY_SOURCE
        dx12.ComputeContext.bufferBarrier(cmd.?, uav_buf, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        ctx.copyResource(readback, uav_buf);

        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseFailed2;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 2 done (sample)\n", .{});
    }

    // Verify: texture was written with [tid.x * 2 + 100], sampling should read same values
    const ptr = try dx12.ComputeContext.mapBuffer(readback);
    defer dx12.ComputeContext.unmapBuffer(readback);
    const data: [*]f32 = @ptrCast(@alignCast(ptr));

    var pass: bool = true;
    for (0..num_elements) |i| {
        const expected: f32 = @floatFromInt(@as(u32, @intCast(i)) * 2 + 100);
        const tolerance: f32 = if (expected == 0) @as(f32, 0.001) else @abs(expected) * 0.001;
        const diff = @abs(data[i] - expected);
        if (diff > tolerance) {
            std.debug.print("FAIL[{}]: got {} expected {} (diff={})\n", .{ i, data[i], expected, diff });
            pass = false;
            break;
        }
    }
    if (pass) {
        std.debug.print("PASS: All {} sampled values verified\n", .{num_elements});
    }

    d3d.release(rs1);
    d3d.release(rs2);
    d3d.release(pso1);
    d3d.release(pso2);
}
