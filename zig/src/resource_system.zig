const std = @import("std");
const gpu_ir = @import("gpu_ir.zig");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");
const rs_builder = @import("root_signature_builder.zig");

fn resourceStateToD3D12(rs: gpu_ir.ResourceState) u32 {
    return switch (rs) {
        .common => d3d.D3D12_RESOURCE_STATE_COMMON,
        .unordered_access => d3d.D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
        .non_pixel_shader_resource => d3d.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
        .pixel_shader_resource => d3d.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
        .copy_source => d3d.D3D12_RESOURCE_STATE_COPY_SOURCE,
        .copy_dest => d3d.D3D12_RESOURCE_STATE_COPY_DEST,
    };
}

pub const ResourceHandle = struct {
    id: gpu_ir.ResourceId,
    d3d_resource: ?*anyopaque = null,
    current_state: gpu_ir.ResourceState = .common,
    desc: gpu_ir.ResourceDesc,
    alloc_index: u32 = 0,
};

pub const ResourcePool = struct {
    resources: std.AutoHashMap(gpu_ir.ResourceId, ResourceHandle),
    next_id: std.atomic.Value(u64),
    allocator: std.mem.Allocator,
    ctx: *dx12.ComputeContext,

    pub fn init(allocator: std.mem.Allocator, ctx: *dx12.ComputeContext) ResourcePool {
        return ResourcePool{
            .resources = std.AutoHashMap(gpu_ir.ResourceId, ResourceHandle).init(allocator),
            .next_id = std.atomic.Value(u64).init(1),
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *ResourcePool) void {
        var it = self.resources.valueIterator();
        while (it.next()) |handle| {
            if (handle.d3d_resource) |res| {
                d3d.release(res);
            }
        }
        self.resources.deinit();
    }

    pub fn createBuffer(self: *ResourcePool, desc: gpu_ir.BufferDesc) !gpu_ir.ResourceId {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const size = if (desc.elements > 0 and desc.stride > 0)
            desc.elements * desc.stride
        else
            desc.size;

        const resource = try self.ctx.createBuffer(
            size,
            .DEFAULT,
            resourceStateToD3D12(.common),
            d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        );

        const handle = ResourceHandle{
            .id = id,
            .d3d_resource = resource,
            .current_state = .common,
            .desc = .{ .buffer = desc },
        };
        try self.resources.put(id, handle);
        return id;
    }

    pub fn createTexture2D(self: *ResourcePool, desc: gpu_ir.TextureDesc) !gpu_ir.ResourceId {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const dxgi_format: d3d.DXGI_FORMAT = @enumFromInt(desc.format.toDXGI());

        const resource = try self.ctx.createTexture2D(
            desc.width,
            desc.height,
            dxgi_format,
            resourceStateToD3D12(.common),
            d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        );

        const handle = ResourceHandle{
            .id = id,
            .d3d_resource = resource,
            .current_state = .common,
            .desc = .{ .texture2d = desc },
        };
        try self.resources.put(id, handle);
        return id;
    }

    pub fn getResource(self: *ResourcePool, id: gpu_ir.ResourceId) ?*ResourceHandle {
        return self.resources.getPtr(id);
    }

    pub fn getD3DResource(self: *ResourcePool, id: gpu_ir.ResourceId) ?*anyopaque {
        const handle = self.resources.getPtr(id) orelse return null;
        return handle.d3d_resource;
    }

    pub fn transitionBarrier(
        self: *ResourcePool,
        cmd_list: ?*anyopaque,
        id: gpu_ir.ResourceId,
        state_after: gpu_ir.ResourceState,
    ) void {
        const handle = self.resources.getPtr(id) orelse return;
        if (handle.current_state == state_after) return;
        dx12.ComputeContext.bufferBarrier(
            cmd_list,
            handle.d3d_resource.?,
            resourceStateToD3D12(handle.current_state),
            resourceStateToD3D12(state_after),
        );
        handle.current_state = state_after;
    }

    pub fn applyBarriers(
        self: *ResourcePool,
        cmd_list: ?*anyopaque,
        barriers: []const gpu_ir.BarrierDesc,
    ) void {
        for (barriers) |b| {
            self.transitionBarrier(cmd_list, b.resource_id, b.state_after);
        }
    }

    /// Write a single descriptor view (UAV or SRV) for a resource at a CPU handle.
    pub fn writeView(self: *ResourcePool, resource_id: gpu_ir.ResourceId, bind_type: gpu_ir.BindType, cpu_handle: d3d.D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const handle = self.resources.getPtr(resource_id) orelse return;
        switch (bind_type) {
            .uav => {
                switch (handle.desc) {
                    .texture2d => |td| {
                        const dxgi_format: d3d.DXGI_FORMAT = @enumFromInt(td.format.toDXGI());
                        var desc: d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC = undefined;
                        desc.Format = dxgi_format;
                        desc.ViewDimension = .TEXTURE2D;
                        desc._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } };
                        self.ctx.createUAVViewTexture(handle.d3d_resource.?, &desc, cpu_handle);
                    },
                    .buffer => |bd| {
                        var desc: d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC = undefined;
                        desc.Format = .R32_FLOAT;
                        desc.ViewDimension = .BUFFER;
                        desc._u = .{ .Buffer = .{
                            .FirstElement = 0,
                            .NumElements = if (bd.elements > 0) bd.elements else @as(u32, @intCast(bd.size / 4)),
                            .StructureByteStride = 0,
                            .CounterOffsetInBytes = 0,
                            .Flags = 0,
                        } };
                        self.ctx.createUAVView(handle.d3d_resource.?, &desc, cpu_handle);
                    },
                    .sampler => {},
                }
            },
            .srv => {
                switch (handle.desc) {
                    .texture2d => |td| {
                        const dxgi_format: d3d.DXGI_FORMAT = @enumFromInt(td.format.toDXGI());
                        var desc: d3d.D3D12_SHADER_RESOURCE_VIEW_DESC = undefined;
                        desc.Format = dxgi_format;
                        desc.ViewDimension = .TEXTURE2D;
                        desc.Shader4ComponentMapping = 0x1608;
                        desc._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } };
                        self.ctx.createSRV(handle.d3d_resource.?, &desc, cpu_handle);
                    },
                    .buffer => |bd| {
                        var desc: d3d.D3D12_SHADER_RESOURCE_VIEW_DESC = undefined;
                        desc.Format = .R32_FLOAT;
                        desc.ViewDimension = .BUFFER;
                        desc.Shader4ComponentMapping = 0x1608;
                        desc._u = .{ .Buffer = .{
                            .FirstElement = 0,
                            .NumElements = if (bd.elements > 0) bd.elements else @as(u32, @intCast(bd.size / 4)),
                            .StructureByteStride = 0,
                            .Flags = 0,
                        } };
                        self.ctx.createSRV(handle.d3d_resource.?, &desc, cpu_handle);
                    },
                    .sampler => {},
                }
            },
            .cbv => {},
            .sampler => {},
        }
    }

    pub fn setupDescriptorHeap(
        self: *ResourcePool,
        bindings: []const gpu_ir.BindEntry,
        compiled_rs: *const rs_builder.CompiledRS,
        base_offset: u32,
    ) void {
        for (bindings) |entry| {
            // Validate binding exists in RS ranges
            if (!rs_builder.RSRootSignatureBuilder.validateBinding(compiled_rs, entry.key)) {
                std.debug.print("WARN: binding (reg={},space={},{s}) not in RS ranges\n", .{
                    entry.key.reg, entry.key.space, @tagName(entry.key.kind),
                });
                continue;
            }
            const slot = rs_builder.RSRootSignatureBuilder.getHeapOffset(compiled_rs, entry.key) orelse continue;
            const handle = self.resources.getPtr(entry.resource_id) orelse continue;
            const cpu_handle = self.ctx.getUAVCPUHandle(base_offset + slot);
            switch (entry.key.kind) {
                .uav => {
                    switch (handle.desc) {
                        .texture2d => |td| {
                            const dxgi_format: d3d.DXGI_FORMAT = @enumFromInt(td.format.toDXGI());
                            var desc: d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC = undefined;
                            desc.Format = dxgi_format;
                            desc.ViewDimension = .TEXTURE2D;
                            desc._u = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } };
                            self.ctx.createUAVViewTexture(handle.d3d_resource.?, &desc, cpu_handle);
                        },
                        .buffer => |bd| {
                            var desc: d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC = undefined;
                            desc.Format = .R32_FLOAT;
                            desc.ViewDimension = .BUFFER;
                            desc._u = .{ .Buffer = .{
                                .FirstElement = 0,
                                .NumElements = if (bd.elements > 0) bd.elements else @as(u32, @intCast(bd.size / 4)),
                                .StructureByteStride = 0,
                                .CounterOffsetInBytes = 0,
                                .Flags = 0,
                            } };
                            self.ctx.createUAVView(handle.d3d_resource.?, &desc, cpu_handle);
                        },
                        .sampler => {},
                    }
                },
                .srv => {
                    switch (handle.desc) {
                        .texture2d => |td| {
                            const dxgi_format: d3d.DXGI_FORMAT = @enumFromInt(td.format.toDXGI());
                            var desc: d3d.D3D12_SHADER_RESOURCE_VIEW_DESC = undefined;
                            desc.Format = dxgi_format;
                            desc.ViewDimension = .TEXTURE2D;
                            desc.Shader4ComponentMapping = 0x1608;
                            desc._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } };
                            self.ctx.createSRV(handle.d3d_resource.?, &desc, cpu_handle);
                        },
                        .buffer => |bd| {
                            var desc: d3d.D3D12_SHADER_RESOURCE_VIEW_DESC = undefined;
                            desc.Format = .R32_FLOAT;
                            desc.ViewDimension = .BUFFER;
                            desc.Shader4ComponentMapping = 0x1608;
                            desc._u = .{ .Buffer = .{
                                .FirstElement = 0,
                                .NumElements = if (bd.elements > 0) bd.elements else @as(u32, @intCast(bd.size / 4)),
                                .StructureByteStride = 0,
                                .Flags = 0,
                            } };
                            self.ctx.createSRV(handle.d3d_resource.?, &desc, cpu_handle);
                        },
                        .sampler => {},
                    }
                },
                .cbv => {},
                .sampler => {},
            }
        }
    }
};
