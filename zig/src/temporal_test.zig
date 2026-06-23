const std = @import("std");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

pub fn main() !void {
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const W_LOW: u32 = 8;
    const H_LOW: u32 = 8;
    const W_HIGH: u32 = 16;
    const H_HIGH: u32 = 16;

    // --- Root sig 1: UAV only (fill) ---
    var rs1_ranges = [1]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
    };
    var rs1_params = [1]d3d.D3D12_ROOT_PARAMETER{.{ .ParameterType = .DESCRIPTOR_TABLE, ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs1_ranges)) } }, .ShaderVisibility = .ALL }};
    var rs1_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs1_params)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 };
    var blob: ?*anyopaque = null;
    var err_blob: ?*anyopaque = null;
    var hr_ = ctx.D3D12SerializeRootSignature.?(&rs1_desc, 1, &blob, &err_blob);
    if (hr_ < 0) return error.RS1Failed;
    var rs1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs1);
    if (hr_ < 0) return error.RS1Failed;
    d3d.release(blob);

    // --- Root sig 2: SRV×3 + UAV (no sampler, using Load) ---
    var rs2_ranges = [2]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .SRV, .NumDescriptors = 3, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 3 },
    };
    var rs2_params = [1]d3d.D3D12_ROOT_PARAMETER{
        .{ .ParameterType = .DESCRIPTOR_TABLE, ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 2, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs2_ranges)) } }, .ShaderVisibility = .ALL },
    };
    var rs2_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs2_params)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 };
    hr_ = ctx.D3D12SerializeRootSignature.?(&rs2_desc, 1, &blob, &err_blob);
    if (hr_ < 0) { if (err_blob) |eb| d3d.release(eb); return error.RS2Failed; }
    var rs2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs2);
    if (hr_ < 0) return error.RS2Failed;
    d3d.release(blob);

    // --- PSO 1a: Fill low-res ---
    const fill_shader =
        \\RWTexture2D<float> tex : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    tex[tid.xy] = float(tid.x + tid.y * 8);
        \\}
    ;
    const fill_code = try dx12.compileShaderSource(fill_shader);
    var pso1_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs1, .CS = .{ .pShaderBytecode = fill_code.ptr, .BytecodeLength = fill_code.len } };
    var pso1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso1_desc, &d3d.IID_ID3D12PipelineState, &pso1);
    if (hr_ < 0) return error.PSO1Failed;
    defer d3d.release(pso1);

    // --- PSO 1b: Fill prev output ---
    const fill_prev_shader =
        \\RWTexture2D<float> tex : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    tex[tid.xy] = float((tid.x + tid.y * 16) * 2);
        \\}
    ;
    const fill_prev_code = try dx12.compileShaderSource(fill_prev_shader);
    var pso1b_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs1, .CS = .{ .pShaderBytecode = fill_prev_code.ptr, .BytecodeLength = fill_prev_code.len } };
    var pso1b: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso1b_desc, &d3d.IID_ID3D12PipelineState, &pso1b);
    if (hr_ < 0) return error.PSO1bFailed;
    defer d3d.release(pso1b);

    // --- PSO 1c: Fill motion vectors ---
    const fill_mv_shader =
        \\RWTexture2D<float2> tex : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    tex[tid.xy] = float2(2.0, 2.0);
        \\}
    ;
    const fill_mv_code = try dx12.compileShaderSource(fill_mv_shader);
    var pso1c_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs1, .CS = .{ .pShaderBytecode = fill_mv_code.ptr, .BytecodeLength = fill_mv_code.len } };
    var pso1c: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso1c_desc, &d3d.IID_ID3D12PipelineState, &pso1c);
    if (hr_ < 0) return error.PSO1cFailed;
    defer d3d.release(pso1c);

    // --- PSO 2: Temporal reprojection + blend ---
    const temporal_shader =
        \\Texture2D<float> lowResColor : register(t0);
        \\Texture2D<float2> motionVectors : register(t1);
        \\Texture2D<float> prevOutput : register(t2);
        \\RWTexture2D<float> output : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    uint2 outSize; output.GetDimensions(outSize.x, outSize.y);
        \\    uint2 inSize; lowResColor.GetDimensions(inSize.x, inSize.y);
        \\    float2 scale = float2(inSize) / float2(outSize);
        \\    float2 uv = (float2(tid.xy) + 0.5) * scale;
        \\    int2 inPos = int2(uv);
        \\    float currentColor = lowResColor.Load(int3(inPos, 0));
        \\    float2 mv = motionVectors.Load(int3(inPos, 0));
        \\    float2 prevUV = float2(tid.xy) + 0.5 - mv;
        \\    int2 prevPos = int2(prevUV);
        \\    float prevColor = 0;
        \\    if (prevPos.x >= 0 && prevPos.x < int(outSize.x) && prevPos.y >= 0 && prevPos.y < int(outSize.y))
        \\        prevColor = prevOutput.Load(int3(prevPos, 0));
        \\    output[tid.xy] = lerp(currentColor, prevColor, 0.5);
        \\}
    ;
    const temporal_code = try dx12.compileShaderSource(temporal_shader);
    var pso2_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs2, .CS = .{ .pShaderBytecode = temporal_code.ptr, .BytecodeLength = temporal_code.len } };
    var pso2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso2_desc, &d3d.IID_ID3D12PipelineState, &pso2);
    if (hr_ < 0) return error.PSO2Failed;
    defer d3d.release(pso2);

    // --- Textures ---
    const low_res_tex = try ctx.createTexture2D(W_LOW, H_LOW, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(low_res_tex);

    const mv_tex = try ctx.createTexture2D(W_LOW, H_LOW, .R32G32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(mv_tex);

    const prev_tex = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(prev_tex);

    const out_tex = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(out_tex);

    const readback = try ctx.createBuffer(try ctx.getTextureFootprint(W_HIGH, H_HIGH, .R32_FLOAT), .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    defer d3d.release(readback);

    const cmd = ctx.cmd_list;

    // --- Descriptors ---
    // SRVs at slots 0,1,2 (for temporal pass)
    const srv_lr = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } } };
    ctx.createSRV(low_res_tex, &srv_lr, ctx.getUAVCPUHandle(0));
    const srv_mv = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } } };
    ctx.createSRV(mv_tex, &srv_mv, ctx.getUAVCPUHandle(1));
    const srv_prev = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } } };
    ctx.createSRV(prev_tex, &srv_prev, ctx.getUAVCPUHandle(2));

    // UAV at slot 3 (temporal output)
    const out_uav = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } } };
    ctx.createUAVViewTexture(out_tex, &out_uav, ctx.getUAVCPUHandle(3));

    // Fill-pass UAVs at slots 4,5,6
    const fill_lr = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } } };
    ctx.createUAVViewTexture(low_res_tex, &fill_lr, ctx.getUAVCPUHandle(4));
    const fill_mv = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } } };
    ctx.createUAVViewTexture(mv_tex, &fill_mv, ctx.getUAVCPUHandle(5));
    const fill_prev = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } } };
    ctx.createUAVViewTexture(prev_tex, &fill_prev, ctx.getUAVCPUHandle(6));

    // ===== PASS 1a: Fill low-res =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso1);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs1);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(4));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 1, 1, 1);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.Close1;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 1a: low-res fill\n", .{});
    }

    // ===== PASS 1b: Fill prev output =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso1b);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs1);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(6));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 2, 2, 1);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.Close1;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 1b: prev output fill\n", .{});
    }

    // ===== PASS 1c: Fill motion vectors =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso1c);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs1);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(5));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 1, 1, 1);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.Close1;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 1c: mv fill\n", .{});
    }

    // Barriers: all NON_PIXEL_SHADER_RESOURCE for SRV reads
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        dx12.ComputeContext.bufferBarrier(cmd.?, low_res_tex, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, mv_tex, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, prev_tex, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseBarrier;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Barriers done\n", .{});
    }

    // ===== PASS 2: Temporal reprojection + blend =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso2);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs2);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 2, 2, 1);
        dx12.ComputeContext.bufferBarrier(cmd.?, out_tex, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.Close2;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 2: temporal upscale\n", .{});
    }

    // ===== PASS 3: CopyTextureRegion =====
    var row_pitch: u32 = undefined;
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        row_pitch = ctx.copyTextureToBuffer(readback, out_tex, W_HIGH, H_HIGH, .R32_FLOAT);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.Close3;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 3: copy (RowPitch={})\n", .{row_pitch});
    }

    // Verify
    const ptr = try dx12.ComputeContext.mapBuffer(readback);
    defer dx12.ComputeContext.unmapBuffer(readback);
    const data: [*]f32 = @ptrCast(@alignCast(ptr));
    const row_floats = row_pitch / 4;

    std.debug.print("\nRow 2 output: ", .{});
    for (0..W_HIGH) |x| {
        std.debug.print("{d:6.1} ", .{data[2 * row_floats + x]});
    }
    std.debug.print("\n", .{});

    // Expected values using Load (integer texel access, no bilinear):
    // lowResColor[tid] = x + y*8
    // prevOutput[tid] = (x + y*16)*2
    // MV = (2,2)
    // For output pixel (ox, oy):
    //   inPos = int2((ox+0.5)*8/16, (oy+0.5)*8/16) = nearest low-res pixel
    //   current = lowRes[inPos]
    //   mv = MV[inPos] = (2,2)
    //   prevPos = int2((ox+0.5-2), (oy+0.5-2))
    //   prev = prevOutput[prevPos] if in bounds
    //   output = lerp(current, prev, 0.5)

    // (4,2): inPos=int2(2.25, 1.25)=(2,1), current=10
    //        prevPos=int2(2.5, 0.5)=(2,0), prev=(2+0)*2=4
    //        output=lerp(10,4,0.5)=7

    // (8,4): inPos=int2(4.25, 2.25)=(4,2), current=20
    //        prevPos=int2(6.5, 2.5)=(6,2), prev=(6+32)*2=76
    //        output=lerp(20,76,0.5)=48

    // (0,0): inPos=int2(0.25, 0.25)=(0,0), current=0
    //        prevPos=int2(-1.5, -1.5)=(-2,-2) OOB → prev=0
    //        output=lerp(0,0,0.5)=0

    // (2,2): inPos=int2(1.25, 1.25)=(1,1), current=9
    //        prevPos=int2(0.5, 0.5)=(0,0), prev=0
    //        output=lerp(9,0,0.5)=4.5

    var pass: bool = true;
    const checks = [_]struct { ox: u32, oy: u32, expected: f32, tol: f32 }{
        .{ .ox = 0, .oy = 0, .expected = 0, .tol = 0.1 },
        .{ .ox = 4, .oy = 2, .expected = 7, .tol = 0.1 },
        .{ .ox = 8, .oy = 4, .expected = 48, .tol = 0.1 },
        .{ .ox = 2, .oy = 2, .expected = 4.5, .tol = 0.1 },
    };
    for (checks) |c| {
        const actual = data[c.oy * row_floats + c.ox];
        const diff = @abs(actual - c.expected);
        if (diff > c.tol) {
            std.debug.print("FAIL[{}x{}]: got {d:.1} expected {d:.1} (diff={d:.1})\n", .{ c.ox, c.oy, actual, c.expected, diff });
            pass = false;
        } else {
            std.debug.print("OK[{}x{}]: got {d:.1} expected {d:.1}\n", .{ c.ox, c.oy, actual, c.expected });
        }
    }

    if (pass) {
        std.debug.print("\nPASS: Temporal reprojection + blend works\n", .{});
    }

    d3d.release(rs1);
    d3d.release(rs2);
}
