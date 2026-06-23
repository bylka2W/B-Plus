const std = @import("std");
const gpu_ir = @import("gpu_ir.zig");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

/// A binding key mapped to a FrameInputs resource slot.
/// Compiled at graph-build time: zero lookup in execute.
pub const BindSlot = struct {
    key: gpu_ir.BindingKey,
    /// Index into FrameInputs.resources[].
    input_slot: u32,
    /// Descriptor heap offset within this pass's descriptor region.
    heap_offset: u32,
};

/// Fully resolved GPU pass with pre-baked handles.
/// Zero runtime logic: PSO ptr, RS ptr, barriers per pass,
/// bind slots pre-mapped to FrameInputs.
pub const CompiledPass = struct {
    pso: ?*anyopaque,
    root_signature: ?*anyopaque,
    descriptor_base_within_frame: u32,
    descriptor_count: u32,
    grid: [3]u32,
    queue: gpu_ir.QueueType,
    /// Pre-filtered barriers for this pass only. Zero conditionals in execute.
    barriers: []const gpu_ir.BarrierDesc,
    /// Pre-mapped binding slots. Each entry says which input_slot
    /// to read from FrameInputs and which heap_offset to write to.
    bind_slots: []const BindSlot,
};

/// Per-frame input data — the ONLY thing that changes per frame.
/// No graph topology, no plan, no DAG — just flat resource IDs.
pub const FrameInputs = struct {
    /// Flat array of resource IDs. Indexed by BindSlot.input_slot.
    resources: []const gpu_ir.ResourceId,
};

/// Pre-compiled batch (same-queue run of passes).
pub const CompiledBatch = struct {
    passes: []CompiledPass,
    queue: gpu_ir.QueueType,
};

/// Immutable compiled graph artifact.
/// Produced once by compileGraph(), consumed per frame by executeCompiledFrame().
/// No reference to RenderPlan, no graph topology, no DAG.
pub const CompiledGraph = struct {
    compute_batches: []CompiledBatch,
    graphics_batches: []CompiledBatch,
    /// Total descriptor slots needed per frame (sum across all passes).
    frame_descriptor_count: u32,
    /// Number of resource slots in FrameInputs.
    num_resource_slots: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledGraph) void {
        for (self.compute_batches) |*b| {
            for (b.passes) |*p| {
                self.allocator.free(p.barriers);
                self.allocator.free(p.bind_slots);
            }
            self.allocator.free(b.passes);
        }
        self.allocator.free(self.compute_batches);
        for (self.graphics_batches) |*b| {
            for (b.passes) |*p| {
                self.allocator.free(p.barriers);
                self.allocator.free(p.bind_slots);
            }
            self.allocator.free(b.passes);
        }
        self.allocator.free(self.graphics_batches);
    }
};

/// Multi-frame safe descriptor arena.
/// Partitions the shared CBV_SRV_UAV heap into MAX_SLOTS regions.
pub const DescriptorArena = struct {
    ctx: *dx12.ComputeContext,

    pub fn init(ctx: *dx12.ComputeContext) DescriptorArena {
        return .{ .ctx = ctx };
    }

    pub fn passGPUHandle(self: *const DescriptorArena, slot_index: u32, frame_stride: u32, base_within_frame: u32) d3d.D3D12_GPU_DESCRIPTOR_HANDLE {
        return self.ctx.getUAVGPUHandle(slot_index * frame_stride + base_within_frame);
    }

    pub fn passCPUHandle(self: *const DescriptorArena, slot_index: u32, frame_stride: u32, base_within_frame: u32) d3d.D3D12_CPU_DESCRIPTOR_HANDLE {
        return self.ctx.getUAVCPUHandle(slot_index * frame_stride + base_within_frame);
    }
};
