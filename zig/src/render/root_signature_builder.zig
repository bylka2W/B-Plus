const std = @import("std");
const gpu_types = @import("../compiler/gpu/gpu_types.zig");
const d3d = @import("d3d12_bindings.zig");
const dx12 = @import("dx12_compute.zig");

/// A single range in the compiled root signature.
pub const RSRange = struct {
    kind: gpu_types.BindType,
    base_register: u32,
    space: u32,
    count: u32,
    /// Descriptor heap offset for the start of this range.
    heap_offset: u32,
};

/// Per-pass compiled root signature artifact.
pub const CompiledRS = struct {
    root_signature: ?*anyopaque,
    ranges: []const RSRange,
    total_descriptors: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledRS) void {
        d3d.release(self.root_signature);
        self.allocator.free(self.ranges);
    }
};

/// RS cache entry.
const RSCacheEntry = struct {
    compiled: CompiledRS,
};

pub const RSRootSignatureBuilder = struct {
    allocator: std.mem.Allocator,
    ctx: *dx12.ComputeContext,
    /// Cache: hash of BindLayout → CompiledRS
    cache: std.AutoHashMap(u64, RSCacheEntry),

    pub fn init(allocator: std.mem.Allocator, ctx: *dx12.ComputeContext) RSRootSignatureBuilder {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .cache = std.AutoHashMap(u64, RSCacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *RSRootSignatureBuilder) void {
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            entry.compiled.deinit();
        }
        self.cache.deinit();
    }

    fn hashLayout(layout: gpu_types.BindLayout) u64 {
        var h = std.hash.Wyhash.init(0);
        for (layout.slots) |slot| {
            h.update(std.mem.asBytes(&slot.register));
            h.update(std.mem.asBytes(&slot.space));
            h.update(std.mem.asBytes(&slot.bind_type));
            h.update(std.mem.asBytes(&slot.num_descriptors));
        }
        return h.final();
    }

    /// Build per-pass root signature from BindLayout.
    pub fn getOrBuild(self: *RSRootSignatureBuilder, layout: gpu_types.BindLayout) !*const CompiledRS {
        const hash = hashLayout(layout);
        if (self.cache.getPtr(hash)) |entry| return &entry.compiled;

        // Analyze layout: find max register per (type, space)
        var max_srv: [8]u32 = [_]u32{0} ** 8;
        var max_uav: [8]u32 = [_]u32{0} ** 8;
        var max_cbv: [8]u32 = [_]u32{0} ** 8;
        var has_srv: [8]bool = [_]bool{false} ** 8;
        var has_uav: [8]bool = [_]bool{false} ** 8;
        var has_cbv: [8]bool = [_]bool{false} ** 8;

        for (layout.slots) |slot| {
            const s = slot.space;
            if (s >= 8) continue;
            const end_reg = slot.register + slot.num_descriptors;
            switch (slot.bind_type) {
                .srv => {
                    if (end_reg > max_srv[s]) max_srv[s] = end_reg;
                    has_srv[s] = true;
                },
                .uav => {
                    if (end_reg > max_uav[s]) max_uav[s] = end_reg;
                    has_uav[s] = true;
                },
                .cbv => {
                    if (end_reg > max_cbv[s]) max_cbv[s] = end_reg;
                    has_cbv[s] = true;
                },
                .sampler => {},
            }
        }

        // Count non-empty spaces (CBV not in descriptor table — root descriptor)
        var range_count: u32 = 0;
        var ti: u32 = 0;
        while (ti < 8) : (ti += 1) {
            if (has_srv[ti]) range_count += 1;
            if (has_uav[ti]) range_count += 1;
        }

        // Build ranges array and descriptor table ranges
        var total_descriptors: u32 = 0;
        var ranges = try self.allocator.alloc(RSRange, range_count);
        errdefer self.allocator.free(ranges);

        var d3d_ranges_list = try std.ArrayList(d3d.D3D12_DESCRIPTOR_RANGE).initCapacity(self.allocator, range_count);
        defer d3d_ranges_list.deinit();

        var ri: u32 = 0;
        ti = 0;
        while (ti < 8) : (ti += 1) {
            if (has_srv[ti]) {
                const count = max_srv[ti];
                ranges[ri] = .{
                    .kind = .srv,
                    .base_register = 0,
                    .space = ti,
                    .count = count,
                    .heap_offset = total_descriptors,
                };
                d3d_ranges_list.appendAssumeCapacity(.{
                    .RangeType = .SRV,
                    .NumDescriptors = count,
                    .BaseShaderRegister = 0,
                    .RegisterSpace = ti,
                    .OffsetInDescriptorsFromTableStart = total_descriptors,
                });
                total_descriptors += count;
                ri += 1;
            }
            if (has_uav[ti]) {
                const count = max_uav[ti];
                ranges[ri] = .{
                    .kind = .uav,
                    .base_register = 0,
                    .space = ti,
                    .count = count,
                    .heap_offset = total_descriptors,
                };
                d3d_ranges_list.appendAssumeCapacity(.{
                    .RangeType = .UAV,
                    .NumDescriptors = count,
                    .BaseShaderRegister = 0,
                    .RegisterSpace = ti,
                    .OffsetInDescriptorsFromTableStart = total_descriptors,
                });
                total_descriptors += count;
                ri += 1;
            }
        }

        // Create the root signature
        const rs = try self.createRootSignature(d3d_ranges_list.items);

        const compiled = CompiledRS{
            .root_signature = rs,
            .ranges = ranges,
            .total_descriptors = total_descriptors,
            .allocator = self.allocator,
        };

        try self.cache.put(hash, .{ .compiled = compiled });
        const entry = self.cache.getPtr(hash).?;
        return &entry.compiled;
    }

    fn createRootSignature(
        self: *RSRootSignatureBuilder,
        d3d_ranges: []const d3d.D3D12_DESCRIPTOR_RANGE,
    ) !?*anyopaque {
        var params = [1]d3d.D3D12_ROOT_PARAMETER{
            .{
                .ParameterType = .DESCRIPTOR_TABLE,
                ._u = .{ .DescriptorTable = .{
                    .NumDescriptorRanges = @as(u32, @intCast(d3d_ranges.len)),
                    .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(d3d_ranges.ptr)),
                } },
                .ShaderVisibility = .ALL,
            },
        };

        var static_samplers = [1]d3d.D3D12_STATIC_SAMPLER_DESC{
            .{
                .Filter = .MIN_MAG_LINEAR_MIP_POINT,
                .AddressU = .CLAMP,
                .AddressV = .CLAMP,
                .AddressW = .CLAMP,
                .MipLODBias = 0,
                .MaxAnisotropy = 1,
                .ComparisonFunc = .NEVER,
                .BorderColor = .OPAQUE_BLACK,
                .MinLOD = 0,
                .MaxLOD = 3.40282347e+38,
                .ShaderRegister = 0,
                .RegisterSpace = 0,
                .ShaderVisibility = .ALL,
            },
        };

        var root_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{
            .NumParameters = 1,
            .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&params)),
            .NumStaticSamplers = 1,
            .pStaticSamplers = @as(?*const d3d.D3D12_STATIC_SAMPLER_DESC, @ptrCast(&static_samplers)),
            .Flags = 0,
        };

        var blob: ?*anyopaque = null;
        var err_blob: ?*anyopaque = null;
        var hr_ = self.ctx.D3D12SerializeRootSignature.?(
            &root_desc,
            1,
            &blob,
            &err_blob,
        );
        if (hr_ < 0) {
            if (err_blob) |eb| {
                const v = d3d.getBlobVtbl(eb);
                const ptr = v.GetBufferPointer(eb);
                if (@intFromPtr(ptr) != 0)
                    std.debug.print("RS serialize error: {s}\n", .{@as([*:0]u8, @ptrCast(@alignCast(ptr)))});
            }
            return error.RootSignatureFailed;
        }
        defer d3d.release(blob);

        var root_sig: ?*anyopaque = null;
        hr_ = d3d.getDeviceVtbl(self.ctx.device.?).CreateRootSignature(
            self.ctx.device.?,
            0,
            d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?),
            d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?),
            &d3d.IID_ID3D12RootSignature,
            &root_sig,
        );
        if (hr_ < 0) return error.RootSignatureFailed;
        return root_sig;
    }

    /// Validate that a BindingKey is covered by the compiled RSRanges.
    pub fn validateBinding(compiled: *const CompiledRS, key: gpu_types.BindingKey) bool {
        for (compiled.ranges) |r| {
            if (r.kind == key.kind and r.space == key.space) {
                if (key.reg < r.count) return true;
            }
        }
        return false;
    }

    /// Get the descriptor heap offset for a BindingKey within this RS.
    pub fn getHeapOffset(compiled: *const CompiledRS, key: gpu_types.BindingKey) ?u32 {
        for (compiled.ranges) |r| {
            if (r.kind == key.kind and r.space == key.space) {
                if (key.reg < r.count) {
                    return r.heap_offset + key.reg;
                }
            }
        }
        return null;
    }
};
