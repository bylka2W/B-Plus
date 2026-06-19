const std = @import("std");
const gpu_job = @import("gpu_job.zig");
const frame_graph = @import("frame_graph.zig");

pub const GPUScheduler = struct {
    gpu_queue: std.ArrayList(gpu_job.GPUJob),
    frame_budget_ns: u64,
    frame_start_ns: u64,
    gpu_pressure: f32,
    total_dispatched: u64,
    allocator: std.mem.Allocator,

    pub fn init(self: *GPUScheduler, allocator: std.mem.Allocator, frame_budget_ns: u64) void {
        self.* = GPUScheduler{
            .gpu_queue = std.ArrayList(gpu_job.GPUJob).init(allocator),
            .frame_budget_ns = frame_budget_ns,
            .frame_start_ns = @intCast(std.time.nanoTimestamp()),
            .gpu_pressure = 0,
            .total_dispatched = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GPUScheduler) void {
        self.gpu_queue.deinit();
    }

    pub fn remainingBudget(self: *GPUScheduler) i64 {
        const now = std.time.nanoTimestamp();
        return @as(i64, @intCast(self.frame_budget_ns)) -
            @as(i64, @intCast(now - self.frame_start_ns));
    }

    pub fn computeGPUPressure(self: *GPUScheduler) f32 {
        return @as(f32, @floatFromInt(self.gpu_queue.items.len)) / 64.0;
    }

    pub fn submit(self: *GPUScheduler, job: gpu_job.GPUJob) void {
        self.gpu_pressure = self.computeGPUPressure();

        if (self.gpu_pressure > 1.0 and job.dropable) {
            return;
        }

        if (job.deadline_ns > 0 and job.deadline_ns < @as(u64, @intCast(std.time.nanoTimestamp()))) {
            return;
        }

        self.gpu_queue.append(job) catch {};
    }

    pub fn tick(self: *GPUScheduler) void {
        while (self.gpu_queue.items.len > 0) {
            if (self.remainingBudget() < 200_000) {
                break;
            }
            const job = self.gpu_queue.orderedRemove(0);
            self.dispatchToGPU(job);
        }
    }

    fn dispatchToGPU(self: *GPUScheduler, job: gpu_job.GPUJob) void {
        _ = job;
        self.total_dispatched += 1;
    }

    pub fn frameStart(self: *GPUScheduler) void {
        self.frame_start_ns = @intCast(std.time.nanoTimestamp());
    }

    /// Submit an ExecutionPlan with runtime DAG reordering.
    /// Uses Kahn's algorithm on gpu_edges — dispatches ready execs first,
    /// reorders under pressure by priority/criticality within edge constraints.
    pub fn submitFrame(self: *GPUScheduler, plan: *const frame_graph.ExecutionPlan) void {
        self.frameStart();

        const ngpu = plan.gpu.len;
        if (ngpu == 0) return;

        var in_degree = self.allocator.alloc(u32, ngpu) catch return;
        defer self.allocator.free(in_degree);
        @memset(in_degree, 0);

        for (plan.gpu_edges) |e| {
            if (e.to < ngpu) in_degree[e.to] += 1;
        }

        var ready = std.ArrayList(u32).init(self.allocator);
        defer ready.deinit();

        for (0..ngpu) |i| {
            if (in_degree[i] == 0) ready.append(@intCast(i)) catch {};
        }

        // Pressure-based ordering: under load prefer critical/high-priority execs
        self.gpu_pressure = @as(f32, @floatFromInt(ready.items.len)) / @max(@as(f32, @floatFromInt(ngpu)), 1.0);

        while (ready.items.len > 0) {
            if (self.remainingBudget() < 200_000) break;

            // Under high pressure, sort ready queue: critical first, then priority
            if (self.gpu_pressure > 0.8 and ready.items.len > 1) {
                std.sort.block(u32, ready.items, plan.gpu, struct {
                    fn less(gpu: []const frame_graph.GPUExec, p1: u32, p2: u32) bool {
                        const a = gpu[p1].job.priority;
                        const b = gpu[p2].job.priority;
                        if (a != b) return a < b;
                        return gpu[p1].pass_id < gpu[p2].pass_id;
                    }
                }.less);
            }

            const idx = ready.orderedRemove(0);
            const ge = &plan.gpu[idx];

            var gj = ge.job;
            gj.deadline_ns = @as(u64, @intCast(std.time.nanoTimestamp())) + @as(u64, @intCast(self.remainingBudget()));
            self.gpu_queue.append(gj) catch {};

            for (plan.gpu_edges) |e| {
                if (e.from == idx and e.to < ngpu) {
                    in_degree[e.to] -= 1;
                    if (in_degree[e.to] == 0) ready.append(e.to) catch {};
                }
            }
        }

        self.tick();
    }
};
