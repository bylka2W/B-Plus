const std = @import("std");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

const W_LOW = 8;
const H_LOW = 8;
const W_HIGH = 16;
const H_HIGH = 16;

fn makePSO(d: ?*anyopaque, rs: ?*anyopaque, code: []const u8) !?*anyopaque {
    var pso: ?*anyopaque = null;
    var desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs, .CS = .{ .pShaderBytecode = code.ptr, .BytecodeLength = code.len } };
    if (d3d.getDeviceVtbl(d.?).CreateComputePipelineState(d.?, &desc, &d3d.IID_ID3D12PipelineState, &pso) < 0) return error.PSO;
    return pso;
}

fn fill(c: *dx12.ComputeContext, cl: ?*anyopaque, rs: ?*anyopaque, pso: ?*anyopaque, gh: d3d.D3D12_GPU_DESCRIPTOR_HANDLE, gx: u32, gy: u32) !void {
    _ = d3d.getAllocatorVtbl(c.cmd_allocator.?).Reset(c.cmd_allocator.?);
    _ = d3d.getCmdListVtbl(cl.?).Reset(cl.?, c.cmd_allocator, null);
    d3d.getCmdListVtbl(cl.?).SetPipelineState(cl.?, pso);
    d3d.getCmdListVtbl(cl.?).SetComputeRootSignature(cl.?, rs);
    var heaps = [_]?*anyopaque{c.uav_heap};
    d3d.getCmdListVtbl(cl.?).SetDescriptorHeaps(cl.?, 1, &heaps);
    d3d.getCmdListVtbl(cl.?).SetComputeRootDescriptorTable(cl.?, 0, gh);
    d3d.getCmdListVtbl(cl.?).Dispatch(cl.?, gx, gy, 1);
    if (d3d.getCmdListVtbl(cl.?).Close(cl.?) < 0) return error.Close;
    var lists = [_]?*anyopaque{cl};
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

    // RS1: UAV only
    var r1r = [1]d3d.D3D12_DESCRIPTOR_RANGE{.{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 }};
    var r1p = [1]d3d.D3D12_ROOT_PARAMETER{.{ .ParameterType = .DESCRIPTOR_TABLE, ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&r1r)) } }, .ShaderVisibility = .ALL }};
    var r1d = d3d.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&r1p)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 };
    var blob: ?*anyopaque = null; var eblob: ?*anyopaque = null;
    var hr_ = ctx.D3D12SerializeRootSignature.?(&r1d, 1, &blob, &eblob);
    if (hr_ < 0) return error.RS1;
    var rs1: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs1);
    if (hr_ < 0) return error.RS1;
    d3d.release(blob);

    // RS2: SRV×6 + UAV×2 (t0..t5, u0..u1)
    var r2r = [2]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .SRV, .NumDescriptors = 6, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
        .{ .RangeType = .UAV, .NumDescriptors = 2, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 6 },
    };
    var r2p = [1]d3d.D3D12_ROOT_PARAMETER{.{ .ParameterType = .DESCRIPTOR_TABLE, ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 2, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&r2r)) } }, .ShaderVisibility = .ALL }};
    var r2d = d3d.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = 1, .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&r2p)), .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = 0 };
    hr_ = ctx.D3D12SerializeRootSignature.?(&r2d, 1, &blob, &eblob);
    if (hr_ < 0) return error.RS2;
    var rs2: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &rs2);
    if (hr_ < 0) return error.RS2;
    d3d.release(blob);

    // --- Fill shaders ---
    const S_lr = \\RWTexture2D<float> t : register(u0); [numthreads(8,8,1)] void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = float(d.x + d.y * 8); }
    ;
    const S_po = \\RWTexture2D<float> t : register(u0); [numthreads(8,8,1)] void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = d.x < 8 ? 1000.0 : float(int(d.x/2) + int(d.y/2) * 8); }
    ;
    const S_mv = \\RWTexture2D<float2> t : register(u0); [numthreads(8,8,1)] void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = float2(0,0); }
    ;
    const S_dp = \\RWTexture2D<float> t : register(u0); [numthreads(8,8,1)] void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = 1.0; }
    ;
    const S_pd = \\RWTexture2D<float> t : register(u0); [numthreads(8,8,1)] void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = 1.0; }
    ;
    const S_lk = \\RWTexture2D<float> t : register(u0); [numthreads(8,8,1)] void main(uint3 d : SV_DispatchThreadID) { t[d.xy] = 5.0; }
    ;

    const C1 = try dx12.compileShaderSource(S_lr);
    const C2 = try dx12.compileShaderSource(S_po);
    const C3 = try dx12.compileShaderSource(S_mv);
    const C4 = try dx12.compileShaderSource(S_dp);
    const C5 = try dx12.compileShaderSource(S_pd);
    const C6 = try dx12.compileShaderSource(S_lk);

    const P1 = try makePSO(ctx.device.?, rs1, C1);
    const P2 = try makePSO(ctx.device.?, rs1, C2);
    const P3 = try makePSO(ctx.device.?, rs1, C3);
    const P4 = try makePSO(ctx.device.?, rs1, C4);
    const P5 = try makePSO(ctx.device.?, rs1, C5);
    const P6 = try makePSO(ctx.device.?, rs1, C6);
    defer d3d.release(P1); defer d3d.release(P2); defer d3d.release(P3);
    defer d3d.release(P4); defer d3d.release(P5); defer d3d.release(P6);

    // --- Temporal + lock PSO ---
    const lock_shader =
        \\Texture2D<float> lowResColor : register(t0);
        \\Texture2D<float2> motionVectors : register(t1);
        \\Texture2D<float> prevOutput : register(t2);
        \\Texture2D<float> depth : register(t3);
        \\Texture2D<float> prevDepth : register(t4);
        \\Texture2D<float> lockPrev : register(t5);
        \\RWTexture2D<float> output : register(u0);
        \\RWTexture2D<float> lockCurr : register(u1);
        \\[numthreads(8, 8, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    uint2 os; output.GetDimensions(os.x, os.y);
        \\    uint2 is; lowResColor.GetDimensions(is.x, is.y);
        \\    int2 ip = int2((float2(tid.xy) + 0.5) * float2(is) / float2(os));
        \\    float cc = lowResColor.Load(int3(ip, 0));
        \\    float2 mv = motionVectors.Load(int3(ip, 0));
        \\    float cd = depth.Load(int3(ip, 0));
        \\    int2 pp = int2(float2(tid.xy) + 0.5 - mv);
        \\    float pc = 0; float blend = 0; float nl = 0;
        \\    if (pp.x >= 0 && pp.x < int(os.x) && pp.y >= 0 && pp.y < int(os.y)) {
        \\        pc = prevOutput.Load(int3(pp, 0));
        \\        float pd = prevDepth.Load(int3(pp, 0));
        \\        if (abs(cd - pd) < 0.01) {
        \\            float lumaDiff = abs(cc - pc);
        \\            float gf = exp(-(lumaDiff * lumaDiff) / 86900.0);
        \\            float pl = lockPrev.Load(int3(pp, 0));
        \\            if (gf > 0.5) {
        \\                nl = min(pl + 1.0, 10.0);
        \\                blend = 0.5 * (nl / 10.0);
        \\            }
        \\        }
        \\    }
        \\    lockCurr[tid.xy] = nl;
        \\    output[tid.xy] = lerp(cc, pc, blend);
        \\}
    ;
    const lock_code = try dx12.compileShaderSource(lock_shader);
    var pso_lock_desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = rs2, .CS = .{ .pShaderBytecode = lock_code.ptr, .BytecodeLength = lock_code.len } };
    var pso_lock: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &pso_lock_desc, &d3d.IID_ID3D12PipelineState, &pso_lock);
    if (hr_ < 0) return error.PSOLock;
    defer d3d.release(pso_lock);

    // --- Textures ---
    const tex_lr = try ctx.createTexture2D(W_LOW, H_LOW, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_lr);
    const tex_mv = try ctx.createTexture2D(W_LOW, H_LOW, .R32G32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_mv);
    const tex_po = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_po);
    const tex_dp = try ctx.createTexture2D(W_LOW, H_LOW, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_dp);
    const tex_pd = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_pd);
    const tex_lp = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS); // lock prev
    defer d3d.release(tex_lp);
    const tex_lc = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS); // lock curr
    defer d3d.release(tex_lc);
    const tex_out = try ctx.createTexture2D(W_HIGH, H_HIGH, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    defer d3d.release(tex_out);

    const rb_size = try ctx.getTextureFootprint(W_HIGH, H_HIGH, .R32_FLOAT);
    const rb_out = try ctx.createBuffer(rb_size, .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    defer d3d.release(rb_out);
    const rb_lock = try ctx.createBuffer(rb_size, .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    defer d3d.release(rb_lock);

    const cmd = ctx.cmd_list;

    // --- SRVs: 0-5 ---
    const srv_r32 = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1 } } };
    const srv_rg32 = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, .Shader4ComponentMapping = 0x1608, ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1 } } };
    ctx.createSRV(tex_lr, &srv_r32, ctx.getUAVCPUHandle(0));
    ctx.createSRV(tex_mv, &srv_rg32, ctx.getUAVCPUHandle(1));
    ctx.createSRV(tex_po, &srv_r32, ctx.getUAVCPUHandle(2));
    ctx.createSRV(tex_dp, &srv_r32, ctx.getUAVCPUHandle(3));
    ctx.createSRV(tex_pd, &srv_r32, ctx.getUAVCPUHandle(4));
    ctx.createSRV(tex_lp, &srv_r32, ctx.getUAVCPUHandle(5));

    // --- UAVs: 6-7 ---
    const uav_r32 = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0 } } };
    ctx.createUAVViewTexture(tex_out, &uav_r32, ctx.getUAVCPUHandle(6));
    ctx.createUAVViewTexture(tex_lc, &uav_r32, ctx.getUAVCPUHandle(7));

    // --- Fill UAVs: 8-13 ---
    const uav_rg32 = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC{ .Format = .R32G32_FLOAT, .ViewDimension = .TEXTURE2D, ._u = .{ .Texture2D = .{ .MipSlice = 0 } } };
    ctx.createUAVViewTexture(tex_lr, &uav_r32, ctx.getUAVCPUHandle(8));
    ctx.createUAVViewTexture(tex_mv, &uav_rg32, ctx.getUAVCPUHandle(9));
    ctx.createUAVViewTexture(tex_po, &uav_r32, ctx.getUAVCPUHandle(10));
    ctx.createUAVViewTexture(tex_dp, &uav_r32, ctx.getUAVCPUHandle(11));
    ctx.createUAVViewTexture(tex_pd, &uav_r32, ctx.getUAVCPUHandle(12));
    ctx.createUAVViewTexture(tex_lp, &uav_r32, ctx.getUAVCPUHandle(13));

    // Fill passes
    try fill(&ctx, cmd, rs1, P1, ctx.getUAVGPUHandle(8), 1, 1);
    std.debug.print("Fill: low-res pattern\n", .{});
    try fill(&ctx, cmd, rs1, P2, ctx.getUAVGPUHandle(10), 2, 2);
    std.debug.print("Fill: prev output (left=1000, right=match)\n", .{});
    try fill(&ctx, cmd, rs1, P3, ctx.getUAVGPUHandle(9), 1, 1);
    std.debug.print("Fill: mv (0,0)\n", .{});
    try fill(&ctx, cmd, rs1, P4, ctx.getUAVGPUHandle(11), 1, 1);
    std.debug.print("Fill: depth\n", .{});
    try fill(&ctx, cmd, rs1, P5, ctx.getUAVGPUHandle(12), 2, 2);
    std.debug.print("Fill: prev depth\n", .{});
    try fill(&ctx, cmd, rs1, P6, ctx.getUAVGPUHandle(13), 2, 2);
    std.debug.print("Fill: lock prev (5.0)\n", .{});

    // Barriers
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_lr, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_mv, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_po, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_dp, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_pd, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_lp, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        if (d3d.getCmdListVtbl(cmd.?).Close(cmd.?) < 0) return error.Barrier;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Barriers done\n", .{});
    }

    // Temporal + lock pass
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, pso_lock);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, rs2);
        var heaps = [_]?*anyopaque{ctx.uav_heap};
        d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 1, &heaps);
        d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, ctx.getUAVGPUHandle(0));
        d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 2, 2, 1);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_out, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        dx12.ComputeContext.bufferBarrier(cmd.?, tex_lc, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        if (d3d.getCmdListVtbl(cmd.?).Close(cmd.?) < 0) return error.Close;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Pass: temporal + lock\n", .{});
    }

    // Copy output → rb_out
    var rp_out: u32 = undefined;
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        rp_out = ctx.copyTextureToBuffer(rb_out, tex_out, W_HIGH, H_HIGH, .R32_FLOAT);
        if (d3d.getCmdListVtbl(cmd.?).Close(cmd.?) < 0) return error.Close;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
    }
    // Copy lock → rb_lock
    var rp_lock: u32 = undefined;
    {
        _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
        rp_lock = ctx.copyTextureToBuffer(rb_lock, tex_lc, W_HIGH, H_HIGH, .R32_FLOAT);
        if (d3d.getCmdListVtbl(cmd.?).Close(cmd.?) < 0) return error.Close;
        var lists = [_]?*anyopaque{cmd};
        d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
        ctx.fence_value += 1;
        _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
        _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
        _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);
        std.debug.print("Copies done\n", .{});
    }

    // Verify
    const ptr_out = try dx12.ComputeContext.mapBuffer(rb_out);
    defer dx12.ComputeContext.unmapBuffer(rb_out);
    const out: [*]f32 = @ptrCast(@alignCast(ptr_out));

    const ptr_lock = try dx12.ComputeContext.mapBuffer(rb_lock);
    defer dx12.ComputeContext.unmapBuffer(rb_lock);
    const lck: [*]f32 = @ptrCast(@alignCast(ptr_lock));

    const rfo = rp_out / 4;
    const rfl = rp_lock / 4;

    std.debug.print("\nOutput row 2: ", .{});
    for (0..W_HIGH) |x| std.debug.print("{d:6.1} ", .{out[2 * rfo + x]});
    std.debug.print("\nLock row 2:   ", .{});
    for (0..W_HIGH) |x| std.debug.print("{d:6.1} ", .{lck[2 * rfl + x]});
    std.debug.print("\n", .{});

    // Expected lock:
    // Left (x<8): luma mismatch (1000 vs pattern) → lock reset to 0
    // Right (x>=8): luma match → lock increment from 5→6
    // Output:
    // Left: ghosting rejected → output ≈ current (pattern value)
    // Right: lock=6 → blend=0.5*6/10=0.3, prev matches current → output ≈ current

    var pass: bool = true;

    // Lock checks
    const lock_checks = [_]struct { ox: u32, oy: u32, expected: f32, tol: f32 }{
        .{ .ox = 0, .oy = 0, .expected = 0, .tol = 0.1 },  // left: reset
        .{ .ox = 4, .oy = 2, .expected = 0, .tol = 0.1 },  // left: reset
        .{ .ox = 8, .oy = 0, .expected = 6, .tol = 0.1 },  // right: increment 5→6
        .{ .ox = 12, .oy = 4, .expected = 6, .tol = 0.1 }, // right: increment 5→6
    };
    std.debug.print("\nLock verification:\n", .{});
    for (lock_checks) |c| {
        const actual = lck[c.oy * rfl + c.ox];
        const diff = @abs(actual - c.expected);
        if (diff > c.tol) {
            std.debug.print("  FAIL lock[{}x{}]: got {d:.1} expected {d:.1}\n", .{ c.ox, c.oy, actual, c.expected });
            pass = false;
        } else {
            std.debug.print("  OK lock[{}x{}]: got {d:.1} expected {d:.1}\n", .{ c.ox, c.oy, actual, c.expected });
        }
    }

    // Output checks
    const out_checks = [_]struct { ox: u32, oy: u32, expected: f32, tol: f32 }{
        .{ .ox = 0, .oy = 0, .expected = 0, .tol = 2 },   // ghosting rejected → current
        .{ .ox = 4, .oy = 2, .expected = 10, .tol = 2 },  // ghosting rejected → current
        .{ .ox = 8, .oy = 4, .expected = 20, .tol = 2 },  // lock blend → current≈prev
        .{ .ox = 14, .oy = 6, .expected = 31, .tol = 2 }, // lock blend → current≈prev
    };
    std.debug.print("\nOutput verification:\n", .{});
    for (out_checks) |c| {
        const actual = out[c.oy * rfo + c.ox];
        const diff = @abs(actual - c.expected);
        if (diff > c.tol) {
            std.debug.print("  FAIL out[{}x{}]: got {d:.1} expected {d:.1}\n", .{ c.ox, c.oy, actual, c.expected });
            pass = false;
        } else {
            std.debug.print("  OK out[{}x{}]: got {d:.1} expected {d:.1}\n", .{ c.ox, c.oy, actual, c.expected });
        }
    }

    if (pass) std.debug.print("\nPASS: Lock mechanism verified\n", .{});
    d3d.release(rs1);
    d3d.release(rs2);
}
