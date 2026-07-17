const std = @import("std");
const d3d = @import("../../src/render/d3d12_bindings.zig");
const dx12 = @import("../../src/render/dx12_compute.zig");

pub fn main() !void {
    // Minimal test: DIRECT queue + DIRECT command list, same compute shader
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    var queue_desc: d3d.D3D12_COMMAND_QUEUE_DESC = undefined;
    _ = d3d.getQueueVtbl(ctx.queue.?).GetDesc(ctx.queue.?, &queue_desc);
    std.debug.print("queue type = {d} ({s})\n", .{
        @intFromEnum(queue_desc.Type), @tagName(queue_desc.Type),
    });
    const cmd_type = d3d.getCmdListVtbl(ctx.cmd_list.?).GetType(ctx.cmd_list.?);
    std.debug.print("cmdlist type = {d} ({s})\n", .{
        @intFromEnum(cmd_type), @tagName(cmd_type),
    });

    const num_elements: u32 = 64;
    const buf_size: u64 = num_elements * 4;

    const uav_buf = try ctx.createBuffer(buf_size, .DEFAULT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(uav_buf);

    const readback = try ctx.createBuffer(buf_size, .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    errdefer d3d.release(readback);

    const uav_desc = dx12.ComputeContext.createUAVDesc(null, num_elements);
    const cpu_handle = ctx.getUAVCPUHandle(0);
    ctx.createUAVView(uav_buf, &uav_desc, cpu_handle);

    // Try DIRECT command allocator + command list
    var direct_alloc: ?*anyopaque = null;
    var hr = d3d.getDeviceVtbl(ctx.device.?).CreateCommandAllocator(ctx.device.?, .DIRECT, &d3d.IID_ID3D12CommandAllocator, &direct_alloc);
    std.debug.print("CreateDirectAllocator: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
    if (hr < 0) return error.AllocFailed;

    var direct_list: ?*anyopaque = null;
    hr = d3d.getDeviceVtbl(ctx.device.?).CreateCommandList(ctx.device.?, 0, .DIRECT, direct_alloc, null, &d3d.IID_ID3D12GraphicsCommandList, &direct_list);
    std.debug.print("CreateDirectCmdList: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
    if (hr < 0) return error.ListFailed;

    const list_type = d3d.getCmdListVtbl(direct_list.?).GetType(direct_list.?);
    std.debug.print("direct list type = {d} ({s})\n", .{
        @intFromEnum(list_type), @tagName(list_type),
    });

    hr = d3d.getCmdListVtbl(direct_list.?).Close(direct_list.?);
    std.debug.print("Initial close: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});

    // Now record compute commands on the DIRECT command list
    hr = d3d.getCmdListVtbl(direct_list.?).Reset(direct_list.?, direct_alloc, null);
    std.debug.print("Reset: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
    if (hr < 0) return error.ResetFailed;

    d3d.getCmdListVtbl(direct_list.?).SetPipelineState(direct_list.?, ctx.pso);
    d3d.getCmdListVtbl(direct_list.?).SetComputeRootSignature(direct_list.?, ctx.root_sig);

    var heaps = [_]?*anyopaque{ctx.uav_heap};
    d3d.getCmdListVtbl(direct_list.?).SetDescriptorHeaps(direct_list.?, 1, &heaps);

    const gpu_handle = ctx.getUAVGPUHandle(0);
    d3d.getCmdListVtbl(direct_list.?).SetComputeRootDescriptorTable(direct_list.?, 0, gpu_handle);
    d3d.getCmdListVtbl(direct_list.?).Dispatch(direct_list.?, 1, 1, 1);

    dx12.ComputeContext.bufferBarrier(direct_list.?, uav_buf, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
    d3d.getCmdListVtbl(direct_list.?).CopyResource(direct_list.?, readback, uav_buf);

    hr = d3d.getCmdListVtbl(direct_list.?).Close(direct_list.?);
    std.debug.print("Close after recording: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
    if (hr < 0) return error.CloseFailed;

    // Execute on DIRECT queue
    var lists = [_]?*anyopaque{direct_list};
    d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
    ctx.fence_value += 1;
    hr = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
    if (hr < 0) return error.SignalFailed;
    hr = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
    if (hr < 0) return error.FenceFailed;
    _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);

    // Map and verify
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
            std.debug.print("FAIL[{}]: got {} expected {}\n", .{ i, data[i], expected });
            pass = false;
            break;
        }
    }
    if (pass) {
        std.debug.print("PASS: All {} elements verified\n", .{num_elements});
    }

    d3d.release(direct_alloc);
    d3d.release(direct_list);
}
