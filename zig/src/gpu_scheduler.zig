const std = @import("std");
const gpu_job = @import("gpu_job.zig");

/// Pure GPU dispatch sink. No graph awareness, no Kahn scheduling.
/// Called by the unified scheduler with individual ready GPU jobs.
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

    /// Submit a single GPU job (called from main scheduler Kahn loop).
    pub fn submit(self: *GPUScheduler, job: gpu_job.GPUJob) void {
        self.gpu_pressure = self.computeGPUPressure();
        if (self.gpu_pressure > 1.0 and job.dropable) return;
        if (job.deadline_ns > 0 and job.deadline_ns < @as(u64, @intCast(std.time.nanoTimestamp()))) return;
        self.gpu_queue.append(job) catch {};
    }

    /// Flush accumulated GPU jobs within remaining budget.
    pub fn tick(self: *GPUScheduler) void {
        while (self.gpu_queue.items.len > 0) {
            if (self.remainingBudget() < 200_000) break;
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
};
