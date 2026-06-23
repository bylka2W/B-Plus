const std = @import("std");
const windows = std.os.windows;
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

pub const MAX_FRAMES_IN_FLIGHT = 3;

pub const FrameSlot = struct {
    cmd_allocator: ?*anyopaque = null,
    cmd_list: ?*anyopaque = null,
    fence_value: u64 = 0,
};

pub const FrameRuntime = struct {
    device: ?*anyopaque,
    queue: ?*anyopaque,
    fence: ?*anyopaque,
    event: usize,
    uav_heap: ?*anyopaque,
    uav_heap_increment: u32,
    sampler_heap: ?*anyopaque,
    sampler_heap_increment: u32,
    slots: [MAX_FRAMES_IN_FLIGHT]FrameSlot = [_]FrameSlot{.{}} ** MAX_FRAMES_IN_FLIGHT,
    frame_index: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *dx12.ComputeContext) !FrameRuntime {
        var rt = FrameRuntime{
            .device = ctx.device,
            .queue = ctx.queue,
            .fence = ctx.fence,
            .event = ctx.event,
            .uav_heap = ctx.uav_heap,
            .uav_heap_increment = ctx.uav_heap_increment,
            .sampler_heap = ctx.sampler_heap,
            .sampler_heap_increment = ctx.sampler_heap_increment,
            .allocator = allocator,
        };

        for (&rt.slots) |*slot| {
            var allocator_: ?*anyopaque = null;
            var hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateCommandAllocator(
                ctx.device.?,
                .COMPUTE,
                &d3d.IID_ID3D12CommandAllocator,
                &allocator_,
            );
            if (hr_ < 0) return error.CommandAllocatorFailed;
            slot.cmd_allocator = allocator_;

            var cmd_list: ?*anyopaque = null;
            hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateCommandList(
                ctx.device.?,
                0,
                .COMPUTE,
                allocator_,
                null,
                &d3d.IID_ID3D12GraphicsCommandList,
                &cmd_list,
            );
            if (hr_ < 0) return error.CommandListFailed;
            slot.cmd_list = cmd_list;

            _ = d3d.getCmdListVtbl(cmd_list.?).Close(cmd_list.?);
        }

        return rt;
    }

    pub fn deinit(self: *FrameRuntime) void {
        for (&self.slots) |*slot| {
            if (slot.cmd_list) |cl| d3d.release(cl);
            if (slot.cmd_allocator) |ca| d3d.release(ca);
        }
    }

    pub fn beginFrame(self: *FrameRuntime) !*FrameSlot {
        const slot_index = self.frame_index % MAX_FRAMES_IN_FLIGHT;
        const slot = &self.slots[slot_index];

        if (slot.fence_value > 0) {
            const completed = d3d.getFenceVtbl(self.fence.?).GetCompletedValue(self.fence.?);
            if (completed < slot.fence_value) {
                _ = d3d.getFenceVtbl(self.fence.?).SetEventOnCompletion(
                    self.fence.?,
                    slot.fence_value,
                    @ptrFromInt(self.event),
                );
                _ = windows.WaitForSingleObject(@as(windows.HANDLE, @ptrFromInt(self.event)), windows.INFINITE) catch {};
            }
        }

        _ = d3d.getAllocatorVtbl(slot.cmd_allocator.?).Reset(slot.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(slot.cmd_list.?).Reset(slot.cmd_list.?, slot.cmd_allocator, null);

        return slot;
    }

    pub fn endFrame(self: *FrameRuntime, slot: *FrameSlot) !void {
        _ = d3d.getCmdListVtbl(slot.cmd_list.?).Close(slot.cmd_list.?);
        var lists = [_]?*anyopaque{slot.cmd_list};
        d3d.getQueueVtbl(self.queue.?).ExecuteCommandLists(self.queue.?, 1, &lists);

        self.frame_index += 1;
        slot.fence_value = self.frame_index;
        _ = d3d.getQueueVtbl(self.queue.?).Signal(self.queue.?, self.fence, slot.fence_value);
    }

    pub fn drain(self: *FrameRuntime) void {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const fv = self.slots[i].fence_value;
            if (fv > 0) {
                const completed = d3d.getFenceVtbl(self.fence.?).GetCompletedValue(self.fence.?);
                if (completed < fv) {
                    _ = d3d.getFenceVtbl(self.fence.?).SetEventOnCompletion(
                        self.fence.?,
                        fv,
                        @ptrFromInt(self.event),
                    );
                    _ = windows.WaitForSingleObject(@as(windows.HANDLE, @ptrFromInt(self.event)), windows.INFINITE) catch {};
                }
            }
        }
    }

    pub fn currentFrameIndex(self: *const FrameRuntime) u64 {
        return self.frame_index;
    }
};
