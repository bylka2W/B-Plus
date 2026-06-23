const std = @import("std");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

const W_LOW: u32 = 8;
const H_LOW: u32 = 8;
const W_HIGH: u32 = 16;
const H_HIGH: u32 = 16;

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

    // --- RS1: UAV only ---
    var rs1_r = [1]d3d.D3D12_DESCRIPTOR_RANGE{.{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 }};
    var rs1_p = [1]d3d.D3D12_ROOT_PARAMETER{.{ .ParameterType = .DESCRIPTOR_TABLE, ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs1_r)) } }, .ShaderVisibility = .ALL }};
    var rs1_d = d3d.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs1_p)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 };
    var blob: ?*anyopaque = null; var err_blob: ?*anyopaque = null;
    var hr_ = ctx.D3D12SerializeRootSignature.?(&rs1_d, 1, &blob, &err_blob);
    if (hr_ < 0) return error.RS1;
    var rs1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs1);
    if (hr_ < 0) return error.RS1;
    d3d.release(blob);

    // --- RS2: SRV×5 + UAV (t0..t4, u0) ---
    var rs2_r = [2]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .SRV, .NumDescriptors = 5, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 5 },
    };
    var rs2_p = [1]d3d.D3D12_ROOT_PARAMETER{.{ .ParameterType = .DESCRIPTOR_TABLE, ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 2, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&rs2_r)) } }, .ShaderVisibility = .ALL }};
    var rs2_d = d3d.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&rs2_p)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 };
    hr_ = ctx.D3D12SerializeRootSignature.?(&rs2_d, 1, &blob, &err_blob);
    if (hr_ < 0) return error.RS2;
    var rs2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs2);
    if (hr_ < 0) return error.RS2;
    d3d.release(blob);

    // --- Fill shaders ---
    const S1 =
        \\RWTexture2D<float> t : register(u0);
        \\[numthreads(8,8,1)]
        \\void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = float(d.x + d.y * 8); }
    ;
    const S2 =
        \\RWTexture2D<float> t : register(u0);
        \\[numthreads(8,8,1)]
        \\void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = 1000.0; }
    ;
    const S3 =
        \\RWTexture2D<float2> t : register(u0);
        \\[numthreads(8,8,1)]
        \\void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = float2(0,0); }
    ;
    const S4 =
        \\RWTexture2D<float> t : register(u0);
        \\[numthreads(8,8,1)]
        \\void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = 1.0; }
    ;
    const S5 =
        \\RWTexture2D<float> t : register(u0);
        \\[numthreads(8,8,1)]
        \\void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = 1.0; }
    ;

    const C1 = try dx12.compileShaderSource(S1);
    const C2 = try dx12.compileShaderSource(S2);
    const C3 = try dx12.compileShaderSource(S3);
    const C4 = try dx12.compileShaderSource(S4);
    const C5 = try dx12.compileShaderSource(S5);

    const P1 = try makePSO(ctx.device.?, rs1, C1);
    const P2 = try makePSO(ctx.device.?, rs1, C2);
    const P3 = try makePSO(ctx.device.?, rs1, C3);
    const P4 = try makePSO(ctx.device.?, rs1, C4);
    const P5 = try makePSO(ctx.device.?, rs1, C5);
    defer d3d.release(P1); defer d3d.release(P2); defer d3d.release(P3); defer d3d.release(P4); defer d3d.release(P5);

    // --- Anti-ghosting PSO ---
    const ghost_shader =
        \\Texture2D<float> lowResColor : register(t0);
        \\Texture2D<float2> motionVectors : register(t1);
        \\Texture2D<float> prevOutput : register(t2);
        \\Texture2D<float> depth : register(t3);
        \\Texture2D<float> prevDepth : register(t4);
        \\RWTexture2D<float> output : register(u0);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    uint2 os; output.GetDimensions(os.x, os.y);
        \\    uint2 is; lowResColor.GetDimensions(is.x, is.y);
        \\    int2 ip = int2((float2(tid.xy) + 0.5) * float2(is) / float2(os));
        \\    float cc = lowResColor.Load(int3(ip, 0));
        \\    float2 mv = motionVectors.Load(int3(ip, 0));
        \\    float cd = depth.Load(int3(ip, 0));
        \\    int2 pp = int2(float2(tid.xy) + 0.5 - mv);
        \\    float pc = 0; float blend = 0;
        \\    if (pp.x >= 0 && pp.x < int(os.x) && pp.y >= 0 && pp.y < int(os.y)) {
        \\        pc = prevOutput.Load(int3(pp, 0));
        \\        float pd = prevDepth.Load(int3(pp, 0));
        \\        if (abs(cd - pd) < 0.01) {
        \\            float lumaDiff = abs(cc - pc);
        \\            float gf = exp(-(lumaDiff * lumaDiff) / 86900.0);
        \\            blend = 0.5 * gf;
        \\        }
        \\    }
        \\    output[tid.xy] = lerp(cc, pc, blend);
        \\}
    ;
    const ghost_code = try dx12.compileShaderSource(ghost_shader);
    var pso_ghost: ?*anyopaque = null;
    var pso_ghost_d = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs2, .CS = .{ .pShaderBytecode = ghost_code.ptr, .BytecodeLength = ghost_code.len } };
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso_ghost_d, &d3d.IID_ID3D12PipelineState, &pso_ghost);
    if (hr_ < 0) return error.PSOGhost;
    defer d3d.release(pso_ghost);

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

    // --- Descriptors: SRVs 0-4, UAV 5, Fill 6-10 ---
    const srv_r32 = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1 } } };
    const srv_rg32 = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1 } } };
    ctx.createSRV(tex_lr, &srv_r32, ctx.getUAVCPUHandle(0));
    ctx.createSRV(tex_mv, &srv_rg32, ctx.getUAVCPUHandle(1));
    ctx.createSRV(tex_prev, &srv_r32, ctx.getUAVCPUHandle(2));
    ctx.createSRV(tex_depth, &srv_r32, ctx.getUAVCPUHandle(3));
    ctx.createSRV(tex_pdepth, &srv_r32, ctx.getUAVCPUHandle(4));
    const uav_r32 = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0 } } };
    ctx.createUAVViewTexture(tex_out, &uav_r32, ctx.getUAVCPUHandle(5));
    const uav_rg32 = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0 } } };
    ctx.createUAVViewTexture(tex_lr, &uav_r32, ctx.getUAVCPUHandle(6));
    ctx.createUAVViewTexture(tex_mv, &uav_rg32, ctx.getUAVCPUHandle(7));
    ctx.createUAVViewTexture(tex_prev, &uav_r32, ctx.getUAVCPUHandle(8));
    ctx.createUAVViewTexture(tex_depth, &uav_r32, ctx.getUAVCPUHandle(9));
    ctx.createUAVViewTexture(tex_pdepth, &uav_r32, ctx.getUAVCPUHandle(10));

    // --- Fill passes ---
    try execUAVFill(&ctx, cmd.?, rs1, P1, ctx.getUAVGPUHandle(6), 1, 1);
    std.debug.print("Pass 1a: low-res pattern\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, P2, ctx.getUAVGPUHandle(8), 2, 2);
    std.debug.print("Pass 1b: prev output (1000)\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, P3, ctx.getUAVGPUHandle(7), 1, 1);
    std.debug.print("Pass 1c: mv (0,0)\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, P4, ctx.getUAVGPUHandle(9), 1, 1);
    std.debug.print("Pass 1d: depth\n", .{});
    try execUAVFill(&ctx, cmd.?, rs1, P5, ctx.getUAVGPUHandle(10), 2, 2);
    std.debug.print("Pass 1e: prev depth\n", .{});

    // Barriers
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

    // Anti-ghosting temporal pass
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso_ghost);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs2);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 2, 2, 1);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_out, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
        if (hr_ < 0) return error.CloseGhost;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass 2: anti-ghosting temporal\n", .{});
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

    // Scenario: MV=(0,0), so prevPos=outputPos.
    // prevOutput=1000 everywhere, current=lowRes[inPos].
    // lumaDiff = |current - 1000| is large (~940-1000).
    // ghostingFactor = exp(-lumaDiff²/250000) ≈ exp(-3.5..4.0) ≈ 0.01-0.03
    // blend ≈ 0.005-0.015, output ≈ current (ghosting rejected)
    //
    // Without anti-ghosting (blend=0.5): output = lerp(c, 1000, 0.5) = c/2 + 500
    //
    // Current is from lowRes pattern x + y*8 using Load(int2(uv)):
    // For output (ox, oy), inPos = int2((ox+0.5)*0.5, (oy+0.5)*0.5)
    //
    // (0,0): inPos=(0,0), current=0, expected≈0 (vs no-ghost=500)
    // (4,2): inPos=(2,1), current=10, expected≈10 (vs no-ghost=505)
    // (8,4): inPos=(4,2), current=20, expected≈20 (vs no-ghost=510)
    // (14,6): inPos=(7,3), current=31, expected≈31 (vs no-ghost=515.5)

    std.debug.print("\nRow 2 output: ", .{});
    for (0..W_HIGH) |x| std.debug.print("{d:7.1} ", .{data[2 * rf + x]});
    std.debug.print("\n", .{});

    var pass: bool = true;
    const checks = [_]struct { ox: u32, oy: u32, expected: f32, tol: f32 }{
        .{ .ox = 0, .oy = 0, .expected = 0, .tol = 2 },
        .{ .ox = 4, .oy = 2, .expected = 10, .tol = 2 },
        .{ .ox = 8, .oy = 4, .expected = 20, .tol = 2 },
        .{ .ox = 14, .oy = 6, .expected = 31, .tol = 2 },
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

    if (pass) std.debug.print("\nPASS: Anti-ghosting detected large luminance change, rejected history\n", .{});

    d3d.release(rs1);
    d3d.release(rs2);
}
