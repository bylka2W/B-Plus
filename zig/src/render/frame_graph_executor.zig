const std = @import("std");
const frame_graph = @import("frame_graph.zig");
const gpu_types = @import("../compiler/backend/gpu/gpu_types.zig");
const resource_system = @import("resource_system.zig");
const dx12 = @import("dx12_compute.zig");
const d3d = @import("d3d12_bindings.zig");
const rs_builder = @import("root_signature_builder.zig");
const render_graph = @import("render_graph.zig");
const history_manager = @import("history_manager.zig");
const frame_runtime = @import("frame_runtime.zig");
const gpu_scheduler = @import("../runtime/gpu_scheduler.zig");
const compiled_graph = @import("compiled_graph.zig");
const dxil_backend = @import("../compiler/backend/gpu/dxil_backend.zig");

pub const FrameGraphGPUExecutor = struct {
    ctx: *dx12.ComputeContext,
    pool: *resource_system.ResourcePool,
    allocator: std.mem.Allocator,
    rs_bld: rs_builder.RSRootSignatureBuilder,

    // Shader cache: source_hash -> bytecode
    shader_cache: std.AutoHashMap(u64, []const u8),

    // PSO cache: (shader_source_hash, root_sig_ptr) -> pso_ptr
    pso_cache: std.AutoHashMap(u64, ?*anyopaque),

    // Descriptor heap linear allocator (per resolve)
    descriptor_capacity: u32 = 1024,
    descriptor_next_free: u32 = 0,

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

    fn getOrCompileShader(self: *FrameGraphGPUExecutor, shader_key: gpu_types.ShaderKey) ![]const u8 {
        const h = hashSource(shader_key.source);
        if (self.shader_cache.get(h)) |bytecode| return bytecode;

        // Compile via DXIL backend (DXC) — produces DXIL bytecode container
        const result = try dxil_backend.compileHlsl(self.allocator, shader_key.source);
        try self.shader_cache.put(h, result.bytecode);
        // Don't call deinit — bytecode is now owned by shader_cache
        return result.bytecode;
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
        std.debug.print("CreatePSO: hr=0x{x} rs=0x{x} bc_len={}\n", .{ @as(u32, @bitCast(hr_)), @intFromPtr(root_sig), bytecode.len });
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

    fn allocateDescriptorSlots(self: *FrameGraphGPUExecutor, count: u32) !u32 {
        const base = self.descriptor_next_free;
        if (base + count > self.descriptor_capacity) return error.OutOfDescriptorSpace;
        self.descriptor_next_free = base + count;
        return base;
    }

    fn resetDescriptorAllocator(self: *FrameGraphGPUExecutor) void {
        self.descriptor_next_free = 0;
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
            self.pool.setupDescriptorHeap(gpu_pass.bindings.entries, compiled_rs, 0);

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

            self.pool.setupDescriptorHeap(gpu_pass.bindings.entries, compiled_rs, 0);
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
        slot: *frame_runtime.FrameSlot,
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

            const cmd_list = switch (gpu_pass.queue) {
                .compute => slot.compute.list,
                .graphics => slot.graphics.list,
            };

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

            self.pool.setupDescriptorHeap(gpu_pass.bindings.entries, compiled_rs, 0);
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

    /// Phase 3 (resolve): compile shaders, bake PSO/RS, allocate descriptor
    /// heap region, write all views.  After resolve the batch is fully baked.
    fn resolveBatch(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
        batch: *gpu_scheduler.GPUBatch,
    ) !void {
        const count = batch.pass_indices.len;
        var resolved = try self.allocator.alloc(gpu_scheduler.ResolvedPass, count);
        errdefer self.allocator.free(resolved);

        for (batch.pass_indices, 0..) |pass_idx, i| {
            const gp = &plan.gpu_passes[pass_idx];
            const compiled_rs = try self.rs_bld.getOrBuild(gp.pipeline.layout);
            const bytecode = try self.getOrCompileShader(gp.pipeline.shader);
            const pso = try self.getOrCreatePSO(compiled_rs.root_signature, bytecode);

            // Allocate contiguous descriptor region for this pass
            const num_slots = compiled_rs.total_descriptors;
            const base_slot = try self.allocateDescriptorSlots(num_slots);

            // Write all descriptor views into heap at absolute offset
            self.pool.setupDescriptorHeap(gp.bindings.entries, compiled_rs, base_slot);

            resolved[i] = gpu_scheduler.ResolvedPass{
                .pso = pso,
                .root_signature = compiled_rs.root_signature,
                .root_table_gpu_handle = self.ctx.getUAVGPUHandle(base_slot).ptr,
                .descriptor_base_index = base_slot,
                .descriptor_count = num_slots,
                .grid = .{ gp.grid.x, gp.grid.y, gp.grid.z },
            };

            std.debug.print("resolve pass {} (pass_idx={}): '{s}' RS={d}desc @slot{}\n", .{
                gp.pass_id, pass_idx, gp.pipeline.shader.entry,
                num_slots, base_slot,
            });
        }

        if (batch.resolved_passes.len > 0) self.allocator.free(batch.resolved_passes);
        batch.resolved_passes = resolved;
    }

    /// Phase 4 (replay): pure command emission from pre-baked ResolvedPass.
    /// Zero hashmap lookups, zero shader compilation, zero descriptor writes.
    fn executeBatchResolved(
        self: *FrameGraphGPUExecutor,
        batch: *const gpu_scheduler.GPUBatch,
        cmd_list: ?*anyopaque,
    ) void {
        for (batch.resolved_passes, batch.pass_indices) |*rp, pass_idx| {
            const handle = d3d.D3D12_GPU_DESCRIPTOR_HANDLE{ .ptr = rp.root_table_gpu_handle };

            d3d.getCmdListVtbl(cmd_list.?).SetPipelineState(cmd_list.?, rp.pso);
            d3d.getCmdListVtbl(cmd_list.?).SetComputeRootSignature(cmd_list.?, rp.root_signature);
            var heaps = [_]?*anyopaque{self.ctx.uav_heap};
            d3d.getCmdListVtbl(cmd_list.?).SetDescriptorHeaps(cmd_list.?, 1, &heaps);

            // Pre-compressed barriers for this specific pass
            for (batch.barriers) |ab| {
                if (ab.pass_index == pass_idx) {
                    self.pool.transitionBarrier(cmd_list, ab.barrier.resource_id, ab.barrier.state_after);
                }
            }

            d3d.getCmdListVtbl(cmd_list.?).SetComputeRootDescriptorTable(cmd_list.?, 0, handle);
            d3d.getCmdListVtbl(cmd_list.?).Dispatch(cmd_list.?, rp.grid[0], rp.grid[1], rp.grid[2]);

            std.debug.print("exec pass {} @slot{}\n", .{ pass_idx, rp.descriptor_base_index });
        }
    }

    pub fn executeScheduledFrame(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
        schedule: *gpu_scheduler.ScheduledFrame,
        history: *history_manager.HistoryManager,
        runtime: *frame_runtime.FrameRuntime,
    ) !void {
        history.beginFrame();
        const slot = try runtime.beginFrame();

        self.resetDescriptorAllocator();

        // Phase 3 (resolve): compile + bake PSO/RS + write descriptors to heap
        for (schedule.compute.batches) |*batch| {
            try self.resolveBatch(plan, batch);
        }
        for (schedule.graphics.batches) |*batch| {
            try self.resolveBatch(plan, batch);
        }

        // Phase 4 (replay): pure command emission, no hashing, no descriptor writes
        for (schedule.compute.batches) |*batch| {
            self.executeBatchResolved(batch, slot.compute.list);
        }
        for (schedule.graphics.batches) |*batch| {
            self.executeBatchResolved(batch, slot.graphics.list);
        }

        try runtime.endFrame(slot);
        history.flip();

        std.debug.print("Schedule: {} pass ({}C+{}G) {}→{} barrier {}B+{}B batch\n", .{
            schedule.stats.total_passes,
            schedule.stats.compute_passes,
            schedule.stats.graphics_passes,
            schedule.stats.barriers_in,
            schedule.stats.barriers_out,
            schedule.stats.compute_batches,
            schedule.stats.graphics_batches,
        });
    }

    /// Build resource slot table from bindings.
    /// Maps each unique resource_id to a slot index in FrameInputs.
    fn buildResourceSlots(
        allocator: std.mem.Allocator,
        gpu_passes: []const frame_graph.GPUPassDesc,
    ) !struct { slots: std.AutoHashMap(u64, u32), count: u32 } {
        var map = std.AutoHashMap(u64, u32).init(allocator);
        var next: u32 = 0;
        for (gpu_passes) |gp| {
            for (gp.bindings.entries) |entry| {
                if (!map.contains(entry.resource_id)) {
                    try map.put(entry.resource_id, next);
                    next += 1;
                }
            }
        }
        return .{ .slots = map, .count = next };
    }

    /// compileGraph — resolves all PSOs, RSs, pre-filters barriers,
    /// pre-maps bind_slots, plans descriptor layout.
    /// Returns an immutable CompiledGraph with zero runtime references to RenderPlan.
    pub fn compileGraph(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
        schedule: *const gpu_scheduler.ScheduledFrame,
    ) !compiled_graph.CompiledGraph {
        const allocator = self.allocator;

        var comp_batches = try std.ArrayList(compiled_graph.CompiledBatch).initCapacity(allocator, schedule.compute.batches.len);
        defer comp_batches.deinit();
        var gfx_batches = try std.ArrayList(compiled_graph.CompiledBatch).initCapacity(allocator, schedule.graphics.batches.len);
        defer gfx_batches.deinit();

        // Build resource slot table from full plan
        var slot_info = try buildResourceSlots(allocator, plan.gpu_passes);
        defer slot_info.slots.deinit();

        var total_desc: u32 = 0;

        const CompileBatchFn = struct {
            fn compile(
                plan2: *const render_graph.RenderPlan,
                exec: *FrameGraphGPUExecutor,
                batch: *const gpu_scheduler.GPUBatch,
                desc_offset: *u32,
                alloc: std.mem.Allocator,
                resource_slots: *const std.AutoHashMap(u64, u32),
            ) !compiled_graph.CompiledBatch {
                const count = batch.pass_indices.len;
                var passes = try alloc.alloc(compiled_graph.CompiledPass, count);

                for (batch.pass_indices, 0..) |pass_idx, i| {
                    const gp = &plan2.gpu_passes[pass_idx];
                    const compiled_rs = try exec.rs_bld.getOrBuild(gp.pipeline.layout);
                    const bytecode = try exec.getOrCompileShader(gp.pipeline.shader);
                    const pso = try exec.getOrCreatePSO(compiled_rs.root_signature, bytecode);

                    const num_slots = compiled_rs.total_descriptors;
                    const base_slot = desc_offset.*;
                    desc_offset.* += num_slots;

                    // Pre-filter barriers for this pass only (zero conditionals in execute)
                    var pass_barriers = std.ArrayList(gpu_types.BarrierDesc).init(alloc);
                    for (batch.barriers) |ab| {
                        if (ab.pass_index == pass_idx) {
                            try pass_barriers.append(ab.barrier);
                        }
                    }

                    // Pre-map bind_slots: (BindingKey → input_slot, heap_offset)
                    var bs_list = try std.ArrayList(compiled_graph.BindSlot).initCapacity(alloc, gp.bindings.entries.len);
                    for (gp.bindings.entries) |entry| {
                        const input_slot = resource_slots.get(entry.resource_id).?;
                        const heap_offset = rs_builder.RSRootSignatureBuilder.getHeapOffset(compiled_rs, entry.key) orelse {
                            std.debug.print("WARN: binding (reg={},space={},{s}) not in RS ranges\n", .{
                                entry.key.reg, entry.key.space, @tagName(entry.key.kind),
                            });
                            continue;
                        };
                        bs_list.appendAssumeCapacity(.{
                            .key = entry.key,
                            .input_slot = input_slot,
                            .heap_offset = heap_offset,
                        });
                    }
                    const bind_slots = try bs_list.toOwnedSlice();

                    passes[i] = compiled_graph.CompiledPass{
                        .pso = pso,
                        .root_signature = compiled_rs.root_signature,
                        .descriptor_base_within_frame = base_slot,
                        .descriptor_count = num_slots,
                        .grid = .{ gp.grid.x, gp.grid.y, gp.grid.z },
                        .queue = gp.queue,
                        .barriers = try pass_barriers.toOwnedSlice(),
                        .bind_slots = bind_slots,
                    };
                }
                return compiled_graph.CompiledBatch{
                    .passes = passes,
                    .queue = batch.queue,
                };
            }
        };

        for (schedule.compute.batches) |*batch| {
            const cb = try CompileBatchFn.compile(plan, self, batch, &total_desc, allocator, &slot_info.slots);
            comp_batches.appendAssumeCapacity(cb);
        }
        for (schedule.graphics.batches) |*batch| {
            const cb = try CompileBatchFn.compile(plan, self, batch, &total_desc, allocator, &slot_info.slots);
            gfx_batches.appendAssumeCapacity(cb);
        }

        return compiled_graph.CompiledGraph{
            .compute_batches = try comp_batches.toOwnedSlice(),
            .graphics_batches = try gfx_batches.toOwnedSlice(),
            .frame_descriptor_count = total_desc,
            .num_resource_slots = slot_info.count,
            .allocator = allocator,
        };
    }

    /// writeFrameDescriptors — per-frame CPU work.
    /// Writes descriptor views for the current frame slot using FrameInputs.
    /// Zero references to RenderPlan — uses pre-baked bind_slots.
    pub fn writeFrameDescriptors(
        self: *FrameGraphGPUExecutor,
        cg: *const compiled_graph.CompiledGraph,
        inputs: *const compiled_graph.FrameInputs,
        slot_index: u32,
    ) void {
        const frame_stride = cg.frame_descriptor_count;

        for (cg.compute_batches) |*batch| {
            for (batch.passes) |*cp| {
                const pass_base = slot_index * frame_stride + cp.descriptor_base_within_frame;
                for (cp.bind_slots) |bs| {
                    const resource_id = inputs.resources[bs.input_slot];
                    const cpu_handle = self.ctx.getUAVCPUHandle(pass_base + bs.heap_offset);
                    self.pool.writeView(resource_id, bs.key.kind, cpu_handle);
                }
            }
        }
        for (cg.graphics_batches) |*batch| {
            for (batch.passes) |*cp| {
                const pass_base = slot_index * frame_stride + cp.descriptor_base_within_frame;
                for (cp.bind_slots) |bs| {
                    const resource_id = inputs.resources[bs.input_slot];
                    const cpu_handle = self.ctx.getUAVCPUHandle(pass_base + bs.heap_offset);
                    self.pool.writeView(resource_id, bs.key.kind, cpu_handle);
                }
            }
        }
    }

    /// executeCompiledGraph — pure GPU command replay.
    /// Zero descriptor heap writes, zero hash lookups, zero shader compilation,
    /// zero conditionals (barriers pre-filtered per pass).
    pub fn executeCompiledGraph(
        self: *FrameGraphGPUExecutor,
        cg: *const compiled_graph.CompiledGraph,
        slot_index: u32,
        cmd_list: ?*anyopaque,
    ) void {
        var arena = compiled_graph.DescriptorArena.init(self.ctx);
        const frame_stride = cg.frame_descriptor_count;
        var heaps = [_]?*anyopaque{ self.ctx.uav_heap, self.ctx.sampler_heap };
        d3d.getCmdListVtbl(cmd_list.?).SetDescriptorHeaps(cmd_list.?, 2, &heaps);

        for (cg.compute_batches) |*batch| {
            for (batch.passes) |*cp| {
                d3d.getCmdListVtbl(cmd_list.?).SetPipelineState(cmd_list.?, cp.pso);
                d3d.getCmdListVtbl(cmd_list.?).SetComputeRootSignature(cmd_list.?, cp.root_signature);

                for (cp.barriers) |b| {
                    self.pool.transitionBarrier(cmd_list, b.resource_id, b.state_after);
                }

                const handle = arena.passGPUHandle(slot_index, frame_stride, cp.descriptor_base_within_frame);
                d3d.getCmdListVtbl(cmd_list.?).SetComputeRootDescriptorTable(cmd_list.?, 0, handle);
                d3d.getCmdListVtbl(cmd_list.?).Dispatch(cmd_list.?, cp.grid[0], cp.grid[1], cp.grid[2]);
            }
        }
        for (cg.graphics_batches) |*batch| {
            for (batch.passes) |*cp| {
                d3d.getCmdListVtbl(cmd_list.?).SetPipelineState(cmd_list.?, cp.pso);
                d3d.getCmdListVtbl(cmd_list.?).SetComputeRootSignature(cmd_list.?, cp.root_signature);

                for (cp.barriers) |b| {
                    self.pool.transitionBarrier(cmd_list, b.resource_id, b.state_after);
                }

                const handle = arena.passGPUHandle(slot_index, frame_stride, cp.descriptor_base_within_frame);
                d3d.getCmdListVtbl(cmd_list.?).SetComputeRootDescriptorTable(cmd_list.?, 0, handle);
                d3d.getCmdListVtbl(cmd_list.?).Dispatch(cmd_list.?, cp.grid[0], cp.grid[1], cp.grid[2]);
            }
        }
    }

    /// Full frame pipeline: write descriptors + execute, frame-slot safe.
    /// No RenderPlan, no DAG, no graph topology — only FrameInputs + CompiledGraph.
    pub fn executeCompiledFrame(
        self: *FrameGraphGPUExecutor,
        cg: *const compiled_graph.CompiledGraph,
        inputs: *const compiled_graph.FrameInputs,
        runtime: *frame_runtime.FrameRuntime,
    ) !void {
        const slot = try runtime.beginFrame();
        const slot_index = @as(u32, @intCast(runtime.frame_index % frame_runtime.MAX_FRAMES_IN_FLIGHT));

        self.writeFrameDescriptors(cg, inputs, slot_index);
        self.executeCompiledGraph(cg, slot_index, slot.compute.list);

        try runtime.endFrame(slot);
    }

    pub fn executeFramePipeline(
        self: *FrameGraphGPUExecutor,
        plan: *const render_graph.RenderPlan,
        history: *history_manager.HistoryManager,
        runtime: *frame_runtime.FrameRuntime,
    ) !void {
        history.beginFrame();
        const slot = try runtime.beginFrame();
        try self.executeRenderPlanInSlot(plan, slot);
        try runtime.endFrame(slot);
        history.flip();
    }

};
