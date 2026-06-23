const std = @import("std");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

pub fn main() !void {
    var ctx: dx12.ComputeContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // Verify actual types at runtime
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

    // Create UAV buffer (DEFAULT heap)
    const uav_buf = try ctx.createBuffer(buf_size, .DEFAULT, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    errdefer d3d.release(uav_buf);

    // Create readback buffer (READBACK heap)
    const readback = try ctx.createBuffer(buf_size, .READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_FLAG_NONE);
    errdefer d3d.release(readback);

    // Create UAV view at heap index 0
    const uav_desc = dx12.ComputeContext.createUAVDesc(null, num_elements);
    const cpu_handle = ctx.getUAVCPUHandle(0);
    ctx.createUAVView(uav_buf, &uav_desc, cpu_handle);

    // Record and execute command list
    var hr: i32 = 0;
    hr = d3d.getAllocatorVtbl(ctx.cmd_allocator.?).Reset(ctx.cmd_allocator.?);
    if (hr < 0) return error.AllocatorResetFailed;
    hr = d3d.getCmdListVtbl(ctx.cmd_list.?).Reset(ctx.cmd_list.?, ctx.cmd_allocator, null);
    if (hr < 0) return error.CmdListResetFailed;

    d3d.getCmdListVtbl(ctx.cmd_list.?).SetPipelineState(ctx.cmd_list.?, ctx.pso);
    d3d.getCmdListVtbl(ctx.cmd_list.?).SetComputeRootSignature(ctx.cmd_list.?, ctx.root_sig);

    var heaps = [_]?*anyopaque{ctx.uav_heap};
    d3d.getCmdListVtbl(ctx.cmd_list.?).SetDescriptorHeaps(ctx.cmd_list.?, 1, &heaps);

    const gpu_handle = ctx.getUAVGPUHandle(0);
    d3d.getCmdListVtbl(ctx.cmd_list.?).SetComputeRootDescriptorTable(ctx.cmd_list.?, 0, gpu_handle);
    d3d.getCmdListVtbl(ctx.cmd_list.?).Dispatch(ctx.cmd_list.?, 1, 1, 1);

    dx12.ComputeContext.bufferBarrier(ctx.cmd_list.?, uav_buf, d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
    ctx.copyResource(readback, uav_buf);

    hr = d3d.getCmdListVtbl(ctx.cmd_list.?).Close(ctx.cmd_list.?);
    if (hr < 0) return error.CloseFailed;

    var lists = [_]?*anyopaque{ctx.cmd_list};
    d3d.getQueueVtbl(ctx.queue.?).ExecuteCommandLists(ctx.queue.?, 1, &lists);
    ctx.fence_value += 1;
    hr = d3d.getQueueVtbl(ctx.queue.?).Signal(ctx.queue.?, ctx.fence, ctx.fence_value);
    if (hr < 0) return error.SignalFailed;
    hr = d3d.getFenceVtbl(ctx.fence.?).SetEventOnCompletion(ctx.fence.?, ctx.fence_value, @as(*anyopaque, @ptrFromInt(ctx.event)));
    if (hr < 0) return error.FenceFailed;
    _ = try std.os.windows.WaitForSingleObject(@as(std.os.windows.HANDLE, @ptrFromInt(ctx.event)), 5000);

    // Map and verify data
    const ptr = dx12.ComputeContext.mapBuffer(readback) catch |err| {
        const reason = d3d.getDeviceVtbl(ctx.device.?).GetDeviceRemovedReason(ctx.device.?);
        std.debug.print("Map failed with {}. DeviceRemovedReason = 0x{x}\n", .{ err, @as(u32, @bitCast(reason)) });
        dumpDred(ctx.device.?);
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
}

fn dumpDred(device: *anyopaque) void {
    var dred: ?*anyopaque = null;
    const hr = d3d.getDeviceVtbl(device).base.QueryInterface(device, &d3d.IID_ID3D12DeviceRemovedExtendedData1, &dred);
    if (hr < 0) {
        std.debug.print("DRED QI failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
        return;
    }
    const d = dred orelse {
        std.debug.print("DRED: null\n", .{});
        return;
    };
    var output: d3d.D3D12_DRED_AUTO_BREADCRUMBS_OUTPUT1 = .{ .pHeadAutoBreadcrumbNode = null };
    const dred_hr = d3d.getDredVtbl(d).GetAutoBreadcrumbsOutput1(d, &output);
    if (dred_hr < 0) {
        std.debug.print("GetAutoBreadcrumbsOutput1 failed hr=0x{x}\n", .{@as(u32, @bitCast(dred_hr))});
        return;
    }
    var node = output.pHeadAutoBreadcrumbNode;
    while (node) |n| {
        const last_val = if (n.pLastBreadcrumbValue) |v| v.* else @as(u32, 0);
        std.debug.print("  BreadcrumbCount={d} last={d}\n", .{ n.BreadcrumbCount, last_val });
        if (n.pCommandHistory) |hist| {
            const hist_arr: [*]const d3d.D3D12_AUTO_BREADCRUMB_OP = @ptrCast(hist);
            const last_op = if (last_val > 0 and last_val <= n.BreadcrumbCount) hist_arr[last_val - 1] else hist_arr[0];
            std.debug.print("  Last completed OP: {s}\n", .{@tagName(last_op)});
            if (last_val < n.BreadcrumbCount) {
                const failed_op = hist_arr[last_val];
                std.debug.print("  FAILED OP: {s}\n", .{@tagName(failed_op)});
            }
        }
        node = n.pNext;
    }
    var pf_out: d3d.D3D12_DRED_PAGE_FAULT_OUTPUT1 = .{
        .PageFaultVA = 0,
        .pHeadExistingAllocationNode = null,
        .pHeadRecentFreedAllocationNode = null,
    };
    const pf_hr = d3d.getDredVtbl(d).GetPageFaultAllocationOutput1(d, &pf_out);
    if (pf_hr >= 0 and pf_out.PageFaultVA != 0) {
        std.debug.print("  PageFaultVA=0x{x}\n", .{pf_out.PageFaultVA});
    }
}
