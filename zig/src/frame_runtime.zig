const std = @import("std");
const windows = std.os.windows;
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");
const sched = @import("scheduler.zig");

pub const MAX_FRAMES_IN_FLIGHT = 3;

pub const QueueCmdLists = struct {
    allocator: ?*anyopaque = null,
    list: ?*anyopaque = null,
};

pub const FrameSlot = struct {
    compute: QueueCmdLists = .{},
    graphics: QueueCmdLists = .{},
    fence_value: u64 = 0,
};

pub const FrameRuntime = struct {
    device: ?*anyopaque,
    queue: ?*anyopaque,
    gfx_queue: ?*anyopaque,
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
            .gfx_queue = ctx.queue,
            .fence = ctx.fence,
            .event = ctx.event,
            .uav_heap = ctx.uav_heap,
            .uav_heap_increment = ctx.uav_heap_increment,
            .sampler_heap = ctx.sampler_heap,
            .sampler_heap_increment = ctx.sampler_heap_increment,
            .allocator = allocator,
        };

        for (&rt.slots) |*slot| {
            inline for (.{ .COMPUTE, .DIRECT }) |qtype| {
                var allocator_: ?*anyopaque = null;
                var hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateCommandAllocator(
                    ctx.device.?,
                    qtype,
                    &d3d.IID_ID3D12CommandAllocator,
                    &allocator_,
                );
                if (hr_ < 0) return error.CommandAllocatorFailed;

                var cmd_list: ?*anyopaque = null;
                hr_ = d3d.getDeviceVtbl(ctx.device.?).CreateCommandList(
                    ctx.device.?,
                    0,
                    qtype,
                    allocator_,
                    null,
                    &d3d.IID_ID3D12GraphicsCommandList,
                    &cmd_list,
                );
                if (hr_ < 0) return error.CommandListFailed;

                _ = d3d.getCmdListVtbl(cmd_list.?).Close(cmd_list.?);

                if (qtype == .COMPUTE) {
                    slot.compute = .{ .allocator = allocator_, .list = cmd_list };
                } else {
                    slot.graphics = .{ .allocator = allocator_, .list = cmd_list };
                }
            }
        }

        return rt;
    }

    pub fn deinit(self: *FrameRuntime) void {
        for (&self.slots) |*slot| {
            if (slot.compute.list) |cl| d3d.release(cl);
            if (slot.compute.allocator) |ca| d3d.release(ca);
            if (slot.graphics.list) |cl| d3d.release(cl);
            if (slot.graphics.allocator) |ca| d3d.release(ca);
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

        _ = d3d.getAllocatorVtbl(slot.compute.allocator.?).Reset(slot.compute.allocator.?);
        _ = d3d.getCmdListVtbl(slot.compute.list.?).Reset(slot.compute.list.?, slot.compute.allocator, null);

        _ = d3d.getAllocatorVtbl(slot.graphics.allocator.?).Reset(slot.graphics.allocator.?);
        _ = d3d.getCmdListVtbl(slot.graphics.list.?).Reset(slot.graphics.list.?, slot.graphics.allocator, null);

        return slot;
    }

    pub fn endFrame(self: *FrameRuntime, slot: *FrameSlot) !void {
        _ = d3d.getCmdListVtbl(slot.compute.list.?).Close(slot.compute.list.?);
        _ = d3d.getCmdListVtbl(slot.graphics.list.?).Close(slot.graphics.list.?);

        var compute_lists = [_]?*anyopaque{slot.compute.list};
        d3d.getQueueVtbl(self.queue.?).ExecuteCommandLists(self.queue.?, 1, &compute_lists);

        var graphics_lists = [_]?*anyopaque{slot.graphics.list};
        d3d.getQueueVtbl(self.gfx_queue.?).ExecuteCommandLists(self.gfx_queue.?, 1, &graphics_lists);

        self.frame_index += 1;
        slot.fence_value = self.frame_index;
        _ = d3d.getQueueVtbl(self.queue.?).Signal(self.queue.?, self.fence, slot.fence_value);
        _ = d3d.getQueueVtbl(self.gfx_queue.?).Signal(self.gfx_queue.?, self.fence, slot.fence_value);
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

pub const FrameResources = struct {
    input: []f32,
    output: []f32,
    history: []f32,
    motion_x: []f32,
    motion_y: []f32,
    reactive: []f32,
    depth: []f32,
};

pub const FrameCtx = struct {
    id: u64,
    width: u32,
    height: u32,
    scale: f32,
    resources: *FrameResources,
    jitter_x: f32,
    jitter_y: f32,
};

const FrameStageCtx = struct {
    ctx: *FrameCtx,
    stage: Stage,
    tile_x: u32,
    tile_y: u32,
    tile_w: u32,
    tile_h: u32,
    allocator: std.mem.Allocator,
};

pub const Stage = enum { upsample, sharpen, temporal };

const TileStream = struct {
    jobs: []sched.Job,

    pub fn deinit(ts: *TileStream, allocator: std.mem.Allocator) void {
        allocator.free(ts.jobs);
    }
};

pub const FrameBatch = struct {
    upsample: TileStream,
    sharpen: TileStream,
    temporal: TileStream,

    pub fn deinit(fb: *FrameBatch, allocator: std.mem.Allocator) void {
        fb.upsample.deinit(allocator);
        fb.sharpen.deinit(allocator);
        fb.temporal.deinit(allocator);
    }
};

fn buildStage(allocator: std.mem.Allocator, ctx: *FrameCtx, stage: Stage) !TileStream {
    _ = ctx;
    _ = stage;
    return TileStream{ .jobs = try allocator.alloc(sched.Job, 0) };
}

fn submitStage(pool: *sched.WorkerPool, allocator: std.mem.Allocator, ctx: *FrameCtx, stage: Stage) !TileStream {
    const ts = try buildStage(allocator, ctx, stage);
    for (ts.jobs) |*j| pool.submit(j);
    return ts;
}

pub fn submitFrame(s: *sched.Scheduler, allocator: std.mem.Allocator, ctx: *FrameCtx) !FrameBatch {
    const pool = &s.pool.?;
    var batch = FrameBatch{
        .upsample = try submitStage(pool, allocator, ctx, .upsample),
        .sharpen = TileStream{ .jobs = &.{} },
        .temporal = TileStream{ .jobs = &.{} },
    };
    s.waitAll();

    batch.sharpen = try submitStage(pool, allocator, ctx, .sharpen);
    s.waitAll();

    if (ctx.resources.history.len > 0) {
        batch.temporal = try submitStage(pool, allocator, ctx, .temporal);
        s.waitAll();
    }

    return batch;
}
