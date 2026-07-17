const std = @import("std");
const d3d = @import("../../src/render/d3d12_bindings.zig");
const dx12 = @import("../../src/render/dx12_compute.zig");

pub fn main() !void {
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const num_elements: u32 = 64;
    const tex_width: u32 = 64;
    const tex_height: u32 = 1;
    const buf_size: u64 = num_elements * 4; // 256 bytes

    // Override root sig + PSO for dual-UAV test (texture UAV + buffer UAV)
    // Root signature: one descriptor table with two UAV ranges (u0, u1)
    var ranges = [2]d3d.D3D12_DESCRIPTOR_RANGE{
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 0, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 0 },
        .{ .RangeType = .UAV, .NumDescriptors = 1, .BaseShaderRegister = 1, .RegisterSpace = 0, .OffsetInDescriptorsFromTableStart = 1 },
    };
    var params = [1]d3d.D3D12_ROOT_PARAMETER{
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            ._u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 2, .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&ranges)) } },
            .ShaderVisibility = .ALL,
        },
    };
    var root_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{
        .NumParameters = 1,
        .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&params)),
        .NumStaticSamplers = 0,
        .pStaticSamplers = null,
        .Flags = 0,
    };

    var blob: ?*anyopaque = null;
    var err_blob: ?*anyopaque = null;
    var hr_ = ctx.D3D12SerializeRootSignature.?(&root_desc, 1, &blob, &err_blob);
    if (hr_ < 0) { if (err_blob) |eb| { if (@intFromPtr(d3d.getBlobVtbl(eb).GetBufferPointer(eb)) != 0) std.debug.print("RS err: {s}\n", .{@as([*:0]u8, @ptrCast(d3d.getBlobVtbl(eb).GetBufferPointer(eb)))}); } return error.RootSigFailed; }

    var tex_root_sig: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateRootSignature(ctx.device.?, 0, d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?), d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?), &d3d.IID_ID3D12RootSignature, &tex_root_sig);
    if (hr_ < 0) return error.RootSigFailed;
    d3d.release(blob);

    // PSO: write to RWTexture2D<float> at u0 AND buffer at u1
    const tex_pso_shader =
        \\RWTexture2D<float> tex : register(u0);
        \\RWBuffer<float> buf : register(u1);
        \\[numthreads(64, 1, 1)]
        \\void main(uint3 tid : SV_DispatchThreadID) {
        \\    tex[uint2(tid.x, 0)] = float(tid.x * 2);
        \\    buf[tid.x] = float(tid.x * 3);
        \\}
    ;
    const shader_code = try dx12.compileShaderSource(tex_pso_shader);
    const desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{
        .pRootSignature = tex_root_sig,
        .CS = .{ .pShaderBytecode = shader_code.ptr, .BytecodeLength = shader_code.len },
    };
    var tex_pso: ?*anyopaque = null;
    hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateComputePipelineState(ctx.device.?, &desc, &d3d.IID_ID3D12PipelineState, &tex_pso);
    if (hr_ < 0) return error.PSOFailed;

    // Create texture for UAV (64x1 R32_FLOAT, ALLOW_UNORDERED_ACCESS)
    const texture = try ctx.createTexture2D(tex_width, tex_height, .R32_FLOAT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(texture);

    // Create buffer UAV for output
    const uav_buf = try ctx.createBuffer(buf_size, .DEFAULT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(uav_buf);

    // Create readback buffer
    const footprint_size = try ctx.getTextureFootprint(tex_width, tex_height, .R32_FLOAT);
    std.debug.print("texture footprint size={}\n", .{footprint_size});
    const readback = try ctx.createBuffer(footprint_size, .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    errdefer d3d.release(readback);

    // Create UAV views
    // Index 0: Texture2D UAV
    const tex_uav_desc = ctx.createUAVTexture2DDesc(0);
    const tex_cpu = ctx.getUAVCPUHandle(0);
    ctx.createUAVViewTexture(texture, &tex_uav_desc, tex_cpu);
    // Index 1: Buffer UAV
    const buf_uav_desc = dx12.ComputeContext.createUAVDesc(null, num_elements);
    const buf_cpu = ctx.getUAVCPUHandle(1);
    ctx.createUAVView(uav_buf, &buf_uav_desc, buf_cpu);

    // Record and execute
    const cmd = ctx.cmd_list;
    _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
    _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
    d3d.getCmdListVtbl(cmd.?).SetPipelineState(cmd.?, tex_pso);
    d3d.getCmdListVtbl(cmd.?).SetComputeRootSignature(cmd.?, tex_root_sig);
    var heaps = [_]?*anyopaque{ ctx.uav_heap, ctx.sampler_heap };
    d3d.getCmdListVtbl(cmd.?).SetDescriptorHeaps(cmd.?, 2, &heaps);

    const gpu_handle = ctx.getUAVGPUHandle(0);
    d3d.getCmdListVtbl(cmd.?).SetComputeRootDescriptorTable(cmd.?, 0, gpu_handle);
    d3d.getCmdListVtbl(cmd.?).Dispatch(cmd.?, 1, 1, 1);

    // Readback texture: UNORDERED_ACCESS -> COPY_SOURCE
    dx12.ComputeContext.bufferBarrier(cmd.?, texture, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
    ctx.copyTextureToBuffer(readback, texture, tex_width, tex_height, .R32_FLOAT);
    dx12.ComputeContext.bufferBarrier(cmd.?, texture, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
    if (hr_ < 0) return error.CloseFailed;

    var lists = [_]?*anyopaque{cmd};
    d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
    ctx.fence_value += 1;
    _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
    _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
    _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);

    // Map readback and verify texture data
    const ptr = dx12.ComputeContext.mapBuffer(readback) catch |err| {
        const reason = d3d.getDeviceVtbl(ctx.device.?).GetDeviceRemovedReason(ctx.device.?);
        std.debug.print("Map failed with {}. DeviceRemovedReason = 0x{x}\n", .{ err, @as(u32, @bitCast(reason)) });
        return err;
    };
    defer dx12.ComputeContext.unmapBuffer(readback);

    const data: [*]f32 = @ptrCast(@alignCast(ptr));
    var pass: bool = true;
    for (0..num_elements) |i| {
        const expected: f32 = @floatFromInt(@as(u32, @intCast(i)) * 2);
        if (data[i] != expected) {
            std.debug.print("TEX FAIL[{}]: got {} expected {}\n", .{ i, data[i], expected });
            pass = false;
            break;
        }
    }
    if (pass) {
        std.debug.print("PASS: Texture UAV write verified ({} elements)\n", .{num_elements});
    }

    // Also verify buffer UAV data
    const readback_buf = try ctx.createBuffer(buf_size, .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    defer d3d.release(readback_buf);

    // Barrier + copy for buffer
    // Re-record command list for buffer copy
    _ = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
    _ = d3d.getCmdListVtbl(cmd.?).Reset(cmd.?, ctx.cmd_allocator, null);
    dx12.ComputeContext.bufferBarrier(cmd.?, uav_buf, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
    ctx.copyResource(readback_buf, uav_buf);
    hr_ = d3d.getCmdListVtbl(cmd.?).Close(cmd.?);
    if (hr_ < 0) return error.CloseFailed;

    lists = [_]?*anyopaque{cmd};
    d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
    ctx.fence_value += 1;
    _ = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
    _ = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
    _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);

    const ptr2 = try dx12.ComputeContext.mapBuffer(readback_buf);
    defer dx12.ComputeContext.unmapBuffer(readback_buf);
    const buf_data: [*]f32 = @ptrCast(@alignCast(ptr2));
    var buf_pass: bool = true;
    for (0..num_elements) |i| {
        const expected: f32 = @floatFromInt(@as(u32, @intCast(i)) * 3);
        if (buf_data[i] != expected) {
            std.debug.print("BUF FAIL[{}]: got {} expected {}\n", .{ i, buf_data[i], expected });
            buf_pass = false;
            break;
        }
    }
    if (buf_pass) {
        std.debug.print("PASS: Buffer UAV write verified ({} elements)\n", .{num_elements});
    }

    d3d.release(tex_root_sig);
    d3d.release(tex_pso);
}
