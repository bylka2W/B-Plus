const std = @import("std");
const frame_graph = @import("frame_graph.zig");
const gpu_ir = @import("gpu_ir.zig");
const resource_system = @import("resource_system.zig");
const dx12 = @import("dx12_compute.zig");
const d3d = @import("d3d12_bindings.zig");
const rs_builder = @import("root_signature_builder.zig");
const render_graph = @import("render_graph.zig");
const history_manager = @import("history_manager.zig");
const frame_runtime = @import("frame_runtime.zig");

pub const FrameGraphGPUExecutor = struct {
    ctx: *dx12.ComputeContext,
    pool: *resource_system.ResourcePool,
    allocator: std.mem.Allocator,
    rs_bld: rs_builder.RSRootSignatureBuilder,

    // Shader cache: source_hash -> bytecode
    shader_cache: std.AutoHashMap(u64, []const u8),

    // PSO cache: (shader_source_hash, root_sig_ptr) -> pso_ptr
    pso_cache: std.AutoHashMap(u64, ?*anyopaque),

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *dx12.ComputeContext,
        pool: *resource_system.ResourcePool,
    ) FrameGraphGPUExecutor {
        return FrameGraphGPUExecutor{
            .ctx = ctx,
            .pool = pool,
            .allocator = allocator,
            .rs_bld = rs_builder.RSRootSignatureBuilder.init(allocator, ctx),
            .shader_cache = std.AutoHashMap(u64, []const u8).init(allocator),
            .pso_cache = std.AutoHashMap(u64, ?*anyopaque).init(allocator),
        };
    }

    pub fn deinit(self: *FrameGraphGPUExecutor) void {
        self.shader_cache.deinit();
        self.rs_bld.deinit();

        var pc_it = self.pso_cache.valueIterator();
        while (pc_it.next()) |pso| {
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

    fn getOrCompileShader(self: *FrameGraphGPUExecutor, shader_key: gpu_ir.ShaderKey) ![]const u8 {
        const h = hashSource(shader_key.source);
        if (self.shader_cache.get(h)) |bytecode| return bytecode;

        const bytecode = try dx12.compileShaderSource(shader_key.source);
        try self.shader_cache.put(h, bytecode);
        return bytecode;
    }

    fn createPSO(self: *FrameGraphGPUExecutor, root_sig: ?*anyopaque, bytecode: []const u8) !?*anyopaque {
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

    fn getOrCreatePSO(self: *FrameGraphGPUExecutor, root_sig: ?*anyopaque, bytecode: []const u8) !?*anyopaque {
        const shader_hash = hashSource(bytecode);
        const cache_key = hashShaderAndSig(shader_hash, root_sig);

        if (self.pso_cache.get(cache_key)) |pso| return pso;
        const pso = try self.createPSO(root_sig, bytecode);
        try self.pso_cache.put(cache_key, pso);
        return pso;
    }

    pub fn execute(
        self: *FrameGraphGPUExecutor,
        plan: *const frame_graph.ExecutionPlan,
        gpu_passes: []const frame_graph.GPUPassDesc,
    ) !void {
        for (plan.nodes) |node| {
            const pass_id = switch (node.kind) {
                .gpu => |g| g.pass_id,
                .render => |r| r.pass_id,
                else => continue,
            };

            // Find matching GPU pass descriptor
            const gpu_pass = for (gpu_passes) |gp| {
                if (gp.pass_id == pass_id) break &gp;
            } else continue;

            // Per-pass root signature compiled from BindLayout
            const compiled_rs = try self.rs_bld.getOrBuild(gpu_pass.pipeline.layout);

            // Compile shader
            const bytecode = try self.getOrCompileShader(gpu_pass.pipeline.shader);

            // Create or get PSO (per-pass RS, per-pass PSO)
            const pso = try self.getOrCreatePSO(compiled_rs.root_signature, bytecode);

            // Reset command list
            _ = d3d.getAllocatorVtbl(self.ctx.cmd_allocator.?).Reset(self.ctx.cmd_allocator.?);
            _ = d3d.getCmdListVtbl(self.ctx.cmd_list.?).Reset(self.ctx.cmd_list.?, self.ctx.cmd_allocator, null);
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetPipelineState(self.ctx.cmd_list.?, pso);
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetComputeRootSignature(self.ctx.cmd_list.?, compiled_rs.root_signature);
            var heaps = [_]?*anyopaque{ self.ctx.uav_heap, self.ctx.sampler_heap };
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetDescriptorHeaps(self.ctx.cmd_list.?, 2, &heaps);

            // Apply barriers before
            self.pool.applyBarriers(self.ctx.cmd_list.?, gpu_pass.barriers_before);

            // Set up descriptors: RS-driven allocation with validation
            self.pool.setupDescriptorHeap(gpu_pass.bindings.entries, compiled_rs);

            // Set root descriptor table (all ranges start at heap offset 0)
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetComputeRootDescriptorTable(
                self.ctx.cmd_list.?,
                0,
                self.ctx.getUAVGPUHandle(0),
            );

            // Dispatch
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).Dispatch(
                self.ctx.cmd_list.?,
                gpu_pass.grid.x,
                gpu_pass.grid.y,
                gpu_pass.grid.z,
            );

            // Apply barriers after
            self.pool.applyBarriers(self.ctx.cmd_list.?, gpu_pass.barriers_after);

            // Close and submit
            _ = d3d.getCmdListVtbl(self.ctx.cmd_list.?).Close(self.ctx.cmd_list.?);
            var lists = [_]?*anyopaque{self.ctx.cmd_list};
            d3d.getQueueVtbl(self.ctx.queue.?).ExecuteCommandLists(self.ctx.queue.?, 1, &lists);

            std.debug.print("GPU pass {}: '{s}' dispatched ({},{},{}) RS={d} descriptors\n", .{
                gpu_pass.pass_id, gpu_pass.pipeline.shader.entry,
                gpu_pass.grid.x,  gpu_pass.grid.y,
                gpu_pass.grid.z,  compiled_rs.total_descriptors,
            });
        }

        // Wait for all GPU work
        _ = try self.ctx.submitAndWait();
    }

    pub fn executeRenderPlan(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
    ) !void {
        for (plan.nodes, 0..) |node, ni| {
            const pass_id = switch (node.kind) {
                .gpu => |g| g.pass_id,
                .render => |r| r.pass_id,
                else => continue,
            };

            const gpu_pass = for (plan.gpu_passes) |gp| {
                if (gp.pass_id == pass_id) break &gp;
            } else continue;

            const compiled_rs = try self.rs_bld.getOrBuild(gpu_pass.pipeline.layout);
            const bytecode = try self.getOrCompileShader(gpu_pass.pipeline.shader);
            const pso = try self.getOrCreatePSO(compiled_rs.root_signature, bytecode);

            _ = d3d.getAllocatorVtbl(self.ctx.cmd_allocator.?).Reset(self.ctx.cmd_allocator.?);
            _ = d3d.getCmdListVtbl(self.ctx.cmd_list.?).Reset(self.ctx.cmd_list.?, self.ctx.cmd_allocator, null);
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetPipelineState(self.ctx.cmd_list.?, pso);
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetComputeRootSignature(self.ctx.cmd_list.?, compiled_rs.root_signature);
            var heaps = [_]?*anyopaque{ self.ctx.uav_heap, self.ctx.sampler_heap };
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetDescriptorHeaps(self.ctx.cmd_list.?, 2, &heaps);

            // Auto-barriers for this pass
            for (plan.auto_barriers) |b| {
                if (b.pass_index == ni) {
                    self.pool.transitionBarrier(self.ctx.cmd_list, b.barrier.resource_id, b.barrier.state_after);
                }
            }

            // User barriers (if any)
            self.pool.applyBarriers(self.ctx.cmd_list.?, gpu_pass.barriers_before);

            self.pool.setupDescriptorHeap(gpu_pass.bindings.entries, compiled_rs);
            d3d.getCmdListVtbl(self.ctx.cmd_list.?).SetComputeRootDescriptorTable(
                self.ctx.cmd_list.?,
                0,
                self.ctx.getUAVGPUHandle(0),
            );

            d3d.getCmdListVtbl(self.ctx.cmd_list.?).Dispatch(
                self.ctx.cmd_list.?,
                gpu_pass.grid.x,
                gpu_pass.grid.y,
                gpu_pass.grid.z,
            );

            self.pool.applyBarriers(self.ctx.cmd_list.?, gpu_pass.barriers_after);

            _ = d3d.getCmdListVtbl(self.ctx.cmd_list.?).Close(self.ctx.cmd_list.?);
            var lists = [_]?*anyopaque{self.ctx.cmd_list};
            d3d.getQueueVtbl(self.ctx.queue.?).ExecuteCommandLists(self.ctx.queue.?, 1, &lists);

            std.debug.print("Render pass {}: '{s}' ({},{},{}) RS={d} descriptors\n", .{
                gpu_pass.pass_id, gpu_pass.pipeline.shader.entry,
                gpu_pass.grid.x,  gpu_pass.grid.y,
                gpu_pass.grid.z,  compiled_rs.total_descriptors,
            });
        }

        _ = try self.ctx.submitAndWait();
    }

    pub fn executeRenderPlanInSlot(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
        _cmd_allocator: ?*anyopaque,
        cmd_list: ?*anyopaque,
    ) !void {
        _ = _cmd_allocator;
        for (plan.nodes, 0..) |node, ni| {
            const pass_id = switch (node.kind) {
                .gpu => |g| g.pass_id,
                .render => |r| r.pass_id,
                else => continue,
            };

            const gpu_pass = for (plan.gpu_passes) |gp| {
                if (gp.pass_id == pass_id) break &gp;
            } else continue;

            const compiled_rs = try self.rs_bld.getOrBuild(gpu_pass.pipeline.layout);
            const bytecode = try self.getOrCompileShader(gpu_pass.pipeline.shader);
            const pso = try self.getOrCreatePSO(compiled_rs.root_signature, bytecode);

            d3d.getCmdListVtbl(cmd_list.?).SetPipelineState(cmd_list.?, pso);
            d3d.getCmdListVtbl(cmd_list.?).SetComputeRootSignature(cmd_list.?, compiled_rs.root_signature);
            var heaps = [_]?*anyopaque{ self.ctx.uav_heap, self.ctx.sampler_heap };
            d3d.getCmdListVtbl(cmd_list.?).SetDescriptorHeaps(cmd_list.?, 2, &heaps);

            for (plan.auto_barriers) |b| {
                if (b.pass_index == ni) {
                    self.pool.transitionBarrier(cmd_list, b.barrier.resource_id, b.barrier.state_after);
                }
            }
            self.pool.applyBarriers(cmd_list.?, gpu_pass.barriers_before);

            self.pool.setupDescriptorHeap(gpu_pass.bindings.entries, compiled_rs);
            d3d.getCmdListVtbl(cmd_list.?).SetComputeRootDescriptorTable(
                cmd_list.?,
                0,
                self.ctx.getUAVGPUHandle(0),
            );
            d3d.getCmdListVtbl(cmd_list.?).Dispatch(
                cmd_list.?,
                gpu_pass.grid.x,
                gpu_pass.grid.y,
                gpu_pass.grid.z,
            );
            self.pool.applyBarriers(cmd_list.?, gpu_pass.barriers_after);

            std.debug.print("pass {}: '{s}' ({},{},{}) RS={d} descriptors\n", .{
                gpu_pass.pass_id, gpu_pass.pipeline.shader.entry,
                gpu_pass.grid.x,  gpu_pass.grid.y,
                gpu_pass.grid.z,  compiled_rs.total_descriptors,
            });
        }
    }

    pub fn executeRenderPlanWithHistory(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
        history: *history_manager.HistoryManager,
    ) !void {
        history.beginFrame();
        try self.executeRenderPlan(plan);
        history.flip();
    }

    pub fn executeFramePipeline(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
        history: *history_manager.HistoryManager,
        runtime: *frame_runtime.FrameRuntime,
    ) !void {
        history.beginFrame();
        const slot = try runtime.beginFrame();
        try self.executeRenderPlanInSlot(plan, slot.cmd_allocator, slot.cmd_list);
        try runtime.endFrame(slot);
        history.flip();
    }

};
