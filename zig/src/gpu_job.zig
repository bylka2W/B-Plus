const std = @import("std");

pub const GPUJob = struct {
    id: u32,
    pipeline_id: u32,
    dispatch_x: u32,
    dispatch_y: u32,
    dispatch_z: u32,
    wait_semaphore: u64,
    signal_semaphore: u64,
    deadline_ns: u64,
    priority: u8,
    dropable: bool,
};

pub const Job = union(enum) {
    cpu: *const fn () void,
    gpu: GPUJob,
};
