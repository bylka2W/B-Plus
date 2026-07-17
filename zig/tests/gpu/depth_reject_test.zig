const std = @import("std");
const d3d = @import("../../src/render/d3d12_bindings.zig");
const dx12 = @import("../../src/render/dx12_compute.zig");

fn makePSO(device: ?*anyopaque, rs: ?*anyopaque, code: []const u8) !?*anyopaque {
    var pso: ?*anyopaque = null;
    var desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs, .CS = .{ .pShaderBytecode = code.ptr, .BytecodeLength = code.len } };
    const h = d3d.getDeviceVtbl(device.?).CreateComputePipelineState(device.?, &desc, &d3d.IID_ID3D12PipelineState, &pso);
    if (h < 0) return error.PSOFailed;
    return pso;
}

fn execUAVFill(c: *dx12.ComputeContext, cmd_list: ?*anyopaque, rs: ?*anyopaque, pso: ?*anyopaque, gpu_handle: d3d.D3D12_GPU_DESCRIPTOR_HANDLE, gx: u32, gy: u32) !void {
    _ = d3d.getAllocatorVtbl(c.cmd_allocator.?).Reset(c.cmd_allocator.?);
    _ = d3d.getCmdListVtbl(cmd_list.?).Reset(cmd_list.?, c.cmd_allocator, null);
    d3d.getCmdListVtbl(cmd_list.?).SetPipelineState(cmd_list.?, pso);
    d3d.getCmdListVtbl(cmd_list.?).SetComputeRootSignature(cmd_list.?, rs);
    var heaps = [_]?*anyopaque{c.uav_heap};
    d3d.getCmdListVtbl(cmd_list.?).SetDescriptorHeaps(cmd_list.?, 1, &heaps);
    d3d.getCmdListVtbl(cmd_list.?).SetComputeRootDescriptorTable(cmd_list.?, 0, gpu_handle);
    d3d.getCmdListVtbl(cmd_list.?).Dispatch(cmd_list.?, gx, gy, 1);
    const h = d3d.getCmdListVtbl(cmd_list.?).Close(cmd_list.?);
    if (h < 0) return error.Close;
    var lists = [_]?*anyopaque{cmd_list};
    d3d.getQueueVtbl(c.queue.?).ExecuteCommandLists(c.queue.?, 1, &lists);
    c.fence_value += 1;
    _ = d3d.getQueueVtbl(c.queue.?).Signal(c.queue.?, c.fence, c.fence_value);
    _ = d3d.getFenceVtbl(c.fence.?).SetEventOnCompletion(c.fence.?, c.fence_value, @as(*anyopaque, @ptrFromInt(c.event)));
    _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(c.event)), 5000);
}

pub fn main() !void {
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const W_LOW: u32 = 8;
    const H_LOW: u32 = 8;
    const W_HIGH: u32 = 16;
    const H_HIGH: u32 = 16;

    // --- Root sig 1: UAV only (fill) ---
    var rs1_ranges = [1]d3d.D3D12_DESCRIPTOR_RANGE{.{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 }};
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

    // --- Root sig 2: SRV×5 + UAV (t0..t4, u0) ---
    var rs2_ranges = [2]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .SRV, .NumDescriptors = 5, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 5 },
    };
    var rs2_params = [1]d3d.D3D12_ROOT_PARAMETER{.{ .ParameterType = .DESCRIPTOR_TABLE, ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 2, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs2_ranges)) } }, .ShaderVisibility = .ALL }};
    var rs2_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs2_params)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 };
    hr_ = ctx.D3D12SerializeRootSignature.?(&rs2_desc, 1, &blob, &err_blob);
    if (hr_ < 0) { if (err_blob) |eb| d3d.release(eb); return error.RS2Failed; }
    var rs2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs2);
    if (hr_ < 0) return error.RS2Failed;
    d3d.release(blob);

    // --- Fill shaders ---
    const fill_lr_shader = \\RWTexture2D<float> tex : register(u0); [numthreads(8,8,1)] void main(uint3 t : SV_DispatchThreadID) { tex[t.xy] = float(t.x + t.y * 8); }
    ;
    const fill_mv_shader = \\RWTexture2D<float2> tex : register(u0); [numthreads(8,8,1)] void main(uint3 t : SV_DispatchThreadID) { tex[t.xy] = float2(2.0, 0.0); }
    ;
    const fill_prev_shader = \\RWTexture2D<float> tex : register(u0); [numthreads(8,8,1)] void main(uint3 t : SV_DispatchThreadID) { tex[t.xy] = 999.0; }
    ;
    const fill_depth_shader = \\RWTexture2D<float> tex : register(u0); [numthreads(8,8,1)] void main(uint3 t : SV_DispatchThreadID) { tex[t.xy] = 1.0; }
    ;
    const fill_pdepth_shader = \\RWTexture2D<float> tex : register(u0); [numthreads(8,8,1)] void main(uint3 t : SV_DispatchThreadID) { tex[t.xy] = t.x < 8 ? 1.0 : 10.0; }
    ;

    const code_lr = try dx12.compileShaderSource(fill_lr_shader);
    const code_mv = try dx12.compileShaderSource(fill_mv_shader);
    const code_prev = try dx12.compileShaderSource(fill_prev_shader);
    const code_depth = try dx12.compileShaderSource(fill_depth_shader);
    const code_pdepth = try dx12.compileShaderSource(fill_pdepth_shader);

    const pso_lr = try makePSO(ctx.device.?, rs1, code_lr);
    const pso_mv = try makePSO(ctx.device.?, rs1, code_mv);
    const pso_prev = try makePSO(ctx.device.?, rs1, code_prev);
    const pso_depth = try makePSO(ctx.device.?, rs1, code_depth);
    const pso_pdepth = try makePSO(ctx.device.?, rs1, code_pdepth);
    defer d3d.release(pso_lr);
    defer d3d.release(pso_mv);
    defer d3d.release(pso_prev);
    defer d3d.release(pso_depth);
    defer d3d.release(pso_pdepth);

    // --- Temporal + depth rejection PSO ---
    const temporal_shader =
        \\Texture2D<float> lowResColor : register(t0);
        \\Texture2D<float2> motionVectors : register(t1);
        \\Texture2D<float> prevOutput : register(t2);
        \\Texture2D<float> depth : register(t3);
        \\Texture2D<float> prevDepth : register(t4);
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
        \\    float currentDepth = depth.Load(int3(inPos, 0));
        \\    float2 prevUV = float2(tid.xy) + 0.5 - mv;
        \\    int2 prevPos = int2(prevUV);
        \\    float prevColor = 0;
        \\    float blend = 0.0;
        \\    if (prevPos.x >= 0 && prevPos.x < int(outSize.x) && prevPos.y >= 0 && prevPos.y < int(outSize.y)) {
        \\        prevColor = prevOutput.Load(int3(prevPos, 0));
        \\        float prevDepthVal = prevDepth.Load(int3(prevPos, 0));
        \\        if (abs(currentDepth - prevDepthVal) < 0.01) blend = 0.5;
        \\    }
        \\    output[tid.xy] = lerp(currentColor, prevColor, blend);
        \\}
    ;
    const temporal_code = try dx12.compileShaderSource(temporal_shader);
    var pso_temporal_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs2, .CS = .{ .pShaderBytecode = temporal_code.ptr, .BytecodeLength = temporal_code.len } };
    var pso_temporal: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso_temporal_desc, &d3d.IID_ID3D12PipelineState, &pso_temporal);
    if (hr_ < 0) return error.PSOTemporalFailed;
    defer d3d.release(pso_temporal);

    // --- Textures ---
    const tex_lr = try ctx.createTexture2D(W_LOW, H_LOW, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_lr);
    const tex_mv = try ctx.createTexture2D(W_LOW, H_LOW, .R32G32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_mv);
    const tex_prev = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_prev);
    const tex_depth = try ctx.createTexture2D(W_LOW, H_LOW, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_depth);
    const tex_pdepth = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_pdepth);
    const tex_out = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_out);

    const readback = try ctx.createBuffer(try ctx.getTextureFootprint(W_HIGH, H_HIGH, .R32_FLOAT), .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    defer d3d.release(readback);

    const cmd = ctx.cmd_list;

    // --- SRVs t0..t4 at slots 0..4 ---
    const srv_r32 = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } } };
    const srv_rg32 = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } } };
    ctx.createSRV(tex_lr, &srv_r32, ctx.getUAVCPUHandle(0));
    ctx.createSRV(tex_mv, &srv_rg32, ctx.getUAVCPUHandle(1));
    ctx.createSRV(tex_prev, &srv_r32, ctx.getUAVCPUHandle(2));
    ctx.createSRV(tex_depth, &srv_r32, ctx.getUAVCPUHandle(3));
    ctx.createSRV(tex_pdepth, &srv_r32, ctx.getUAVCPUHandle(4));

    // --- UAV u0 at slot 5 ---
    const uav_r32 = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } } };
    ctx.createUAVViewTexture(tex_out, &uav_r32, ctx.getUAVCPUHandle(5));

    // --- Fill UAVs at slots 6..11 ---
    ctx.createUAVViewTexture(tex_lr, &uav_r32, ctx.getUAVCPUHandle(6));
    const uav_rg32 = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } } };
    ctx.createUAVViewTexture(tex_mv, &uav_rg32, ctx.getUAVCPUHandle(7));
    ctx.createUAVViewTexture(tex_prev, &uav_r32, ctx.getUAVCPUHandle(8));
    ctx.createUAVViewTexture(tex_depth, &uav_r32, ctx.getUAVCPUHandle(9));
    ctx.createUAVViewTexture(tex_pdepth, &uav_r32, ctx.getUAVCPUHandle(10));

    // Helper to execute a fill pass
    try execUAVFill(&ctx, cmd.?, rs1, pso_lr, ctx.getUAVGPUHandle(6), 1, 1);
    std.debug.print("Pass 1a: low-res\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, pso_prev, ctx.getUAVGPUHandle(8), 2, 2);
    std.debug.print("Pass 1b: prev output\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, pso_mv, ctx.getUAVGPUHandle(7), 1, 1);
    std.debug.print("Pass 1c: mv\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, pso_depth, ctx.getUAVGPUHandle(9), 1, 1);
    std.debug.print("Pass 1d: depth\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, pso_pdepth, ctx.getUAVGPUHandle(10), 2, 2);
    std.debug.print("Pass 1e: prev depth\n", .{});

    // Barriers: all to NON_PIXEL_SHADER_RESOURCE
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_lr, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_mv, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_prev, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_depth, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_pdepth, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
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

    // ===== Temporal upscale with depth rejection =====
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso_temporal);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs2);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 2, 2, 1);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_out, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseTemporal;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 2: temporal + depth rejection\n", .{});
    }

    // Copy to readback
    var row_pitch: u32 = undefined;
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        row_pitch = ctx.copyTextureToBuffer(readback, tex_out, W_HIGH, H_HIGH, .R32_FLOAT);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseCopy;
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
    const rf = row_pitch / 4;

    std.debug.print("\nRow 1 output: ", .{});
    for (0..W_HIGH) |x| std.debug.print("{d:7.1} ", .{data[1 * rf + x]});
    std.debug.print("\n", .{});

    // Expected:
    // MV=(2,0). For output (ox, oy):
    //   inPos = int2((ox+0.5)*0.5, (oy+0.5)*0.5)
    //   prevPos = int2(ox+0.5-2, oy+0.5-0) = (ox-2, oy) when truncating
    //
    // prevDepth: x<8 → 1.0, x>=8 → 10.0. depth: all 1.0.
    // If prevDepth == 1.0 (within threshold): blend=0.5, else blend=0
    //
    // (0,1): inPos=(0,0), cur=0, prevPos=(-2,1) OOB → blend=0, output=0
    // (2,1): inPos=(1,0), cur=1, prevPos=(0,1)→prevDepth=1.0, diff=0→blend=0.5,
    //         prev=prevOutput[0,1]=999, output=lerp(1,999,0.5)=500
    // (15,1): inPos=(7,0), cur=7, prevPos=(13,1)→prevDepth=10.0, diff=9→blend=0,
    //          output=7

    var pass: bool = true;
    const checks = [_]struct { ox: u32, oy: u32, expected: f32, tol: f32 }{
        .{ .ox = 0, .oy = 1, .expected = 0, .tol = 0.1 },     // OOB → no history
        .{ .ox = 2, .oy = 1, .expected = 500, .tol = 0.1 },   // depth matches → history used
        .{ .ox = 15, .oy = 1, .expected = 7, .tol = 0.1 },    // depth mismatch → history rejected
        .{ .ox = 9, .oy = 1, .expected = 501.5, .tol = 0.1 }, // prevPos=(7,1), prevDepth=1.0 → history used, lerp(4,999,0.5)=501.5
    };
    for (checks) |c| {
        const actual = data[c.oy * rf + c.ox];
        const diff = @abs(actual - c.expected);
        if (diff > c.tol) {
            std.debug.print("FAIL[{}x{}]: got {d:.1} expected {d:.1} (diff={d:.1})\n", .{ c.ox, c.oy, actual, c.expected, diff });
            pass = false;
        } else {
            std.debug.print("OK[{}x{}]: got {d:.1} expected {d:.1}\n", .{ c.ox, c.oy, actual, c.expected });
        }
    }

    if (pass) std.debug.print("\nPASS: Depth-based disocclusion rejection verified\n", .{});

    d3d.release(rs1);
    d3d.release(rs2);
}
