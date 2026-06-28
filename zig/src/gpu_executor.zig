const std = @import("std");
const gpu_ir = @import("gpu_ir.zig");
const gpu_execution = @import("gpu_execution.zig");
const frame_graph = @import("frame_graph.zig");
const resource_system = @import("resource_system.zig");
const dx12 = @import("dx12_compute.zig");
const d3d = @import("d3d12_bindings.zig");
const rs_builder = @import("root_signature_builder.zig");
const dxil_backend = @import("dxil_backend.zig");
const barrier_opt = @import("barrier_optimizer.zig");

/// Bridges GpuExecutionPlan → D3D12.
/// Compiles shaders, creates PSOs, records command lists, submits.
pub const GpuExecutor = struct {
    ctx: *dx12.ComputeContext,
    pool: *resource_system.ResourcePool,
    allocator: std.mem.Allocator,
    rs_bld: rs_builder.RSRootSignatureBuilder,

    shader_cache: std.AutoHashMap(u64, []const u8),
    pso_cache: std.AutoHashMap(u64, ?*anyopaque),
    descriptor_next_free: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *dx12.ComputeContext,
        pool: *resource_system.ResourcePool,
    ) GpuExecutor {
        return GpuExecutor{
            .ctx = ctx,
            .pool = pool,
            .allocator = allocator,
            .rs_bld = rs_builder.RSRootSignatureBuilder.init(allocator, ctx),
            .shader_cache = std.AutoHashMap(u64, []const u8).init(allocator),
            .pso_cache = std.AutoHashMap(u64, ?*anyopaque).init(allocator),
        };
    }

    pub fn deinit(self: *GpuExecutor) void {
        self.shader_cache.deinit();
        self.rs_bld.deinit();
        var it = self.pso_cache.valueIterator();
        while (it.next()) |pso| {
            if (pso.*) |p| d3d.release(p);
        }
        self.pso_cache.deinit();
    }

    fn hashSource(source: []const u8) u64 {
        return std.hash.Wyhash.hash(0, source);
    }

    fn hashShaderAndSig(shader_hash: u64, root_sig: ?*anyopaque) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&shader_hash));
        const ptr_val = @intFromPtr(root_sig);
        h.update(std.mem.asBytes(&ptr_val));
        return h.final();
    }

    fn getOrCompileShader(self: *GpuExecutor, shader_key: gpu_ir.ShaderKey) ![]const u8 {
        const h = hashSource(shader_key.source);
        if (self.shader_cache.get(h)) |bytecode| return bytecode;
        const result = try dxil_backend.compileHlsl(self.allocator, shader_key.source);
        try self.shader_cache.put(h, result.bytecode);
        return result.bytecode;
    }

    fn createPSO(self: *GpuExecutor, root_sig: ?*anyopaque, bytecode: []const u8) !?*anyopaque {
        var pso: ?*anyopaque = null;
        const desc = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC{
            .pRootSignature = root_sig,
            .CS = .{ .pShaderBytecode = bytecode.ptr, .BytecodeLength = bytecode.len },
        };
        const hr_ = d3d.getDeviceVtbl(self.ctx.device.?).CreateComputePipelineState(
            self.ctx.device.?,
            &desc,
            &d3d.IID_ID3D12PipelineState,
            &pso,
        );
        if (hr_ < 0) return error.PSOFailed;
        return pso;
    }

    fn getOrCreatePSO(self: *GpuExecutor, root_sig: ?*anyopaque, bytecode: []const u8) !?*anyopaque {
        const shader_hash = hashSource(bytecode);
        const cache_key = hashShaderAndSig(shader_hash, root_sig);
        if (self.pso_cache.get(cache_key)) |pso| return pso;
        const pso = try self.createPSO(root_sig, bytecode);
        try self.pso_cache.put(cache_key, pso);
        return pso;
    }

    /// Execute a GpuExecutionPlan on the GPU.
    /// Iterates dispatches in scheduled order, compiles shaders/PSOs on demand,
    /// records all commands into one command list, submits, and waits.
    pub fn execute(
        self: *GpuExecutor,
        plan: *const gpu_execution.GpuExecutionPlan,
        gpu_passes: []const frame_graph.GPUPassDesc,
        barriers: []const barrier_opt.BarrierSlot,
    ) !void {
        _ = d3d.getAllocatorVtbl(self.ctx.cmd_allocator.?).Reset(self.ctx.cmd_allocator.?);
        _ = d3d.getCmdListVtbl(self.ctx.cmd_list.?).Reset(self.ctx.cmd_list.?, self.ctx.cmd_allocator, null);

        var heaps = [_]?*anyopaque{ self.ctx.uav_heap, self.ctx.sampler_heap };
        d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetDescriptorHeaps(self.ctx.cmd_list.?, 2, &heaps);

        for (plan.dispatches) |*disp| {
            const gp = for (gpu_passes) |*gp| {
                if (gp.pass_id == disp.pass_id) break gp;
            } else continue;

            const compiled_rs = try self.rs_bld.getOrBuild(gp.pipeline.layout);
            const bytecode = try self.getOrCompileShader(gp.pipeline.shader);
            const pso = try self.getOrCreatePSO(compiled_rs.root_signature, bytecode);

            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetPipelineState(self.ctx.cmd_list.?, pso);
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetComputeRootSignature(self.ctx.cmd_list.?, compiled_rs.root_signature);

            for (barriers) |b| {
                if (b.pass_index == disp.pass_id) {
                    self.pool.transitionBarrier(self.ctx.cmd_list, b.barrier.resource_id, b.barrier.state_after);
                }
            }
            self.pool.applyBarriers(self.ctx.cmd_list.?, gp.barriers_before);

            self.pool.setupDescriptorHeap(gp.bindings.entries, compiled_rs, 0);
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetComputeRootDescriptorTable(
                self.ctx.cmd_list.?,
                0,
                self.ctx.getUAVGPUHandle(0),
            );

            d3d.getCmdListVtbl(self.ctx.cmd_list.?).Dispatch(
                self.ctx.cmd_list.?,
                disp.group_count_x,
                disp.group_count_y,
                disp.group_count_z,
            );

            self.pool.applyBarriers(self.ctx.cmd_list.?, gp.barriers_after);
        }

        _ = d3d.getCmdListVtbl(self.ctx.cmd_list.?).Close(self.ctx.cmd_list.?);
        var lists = [_]?*anyopaque{self.ctx.cmd_list};
        d3d.getQueueVtbl(self.ctx.queue.?).ExecuteCommandLists(self.ctx.queue.?, 1, &lists);
        _ = try self.ctx.submitAndWait();
    }
};
