const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ResourceKind = enum {
    texture2d,
    rw_texture2d,
    sampler_state,
    structured_buffer,
    constant_buffer,
};

pub const ScalarType = enum {
    f32,
    i32,
    u32,
    f16,
    boolean,
};

pub const VectorWidth = enum(u8) { one = 1, two = 2, three = 3, four = 4 };

pub const GpuType = struct {
    kind: TypeKind,
    pub const TypeKind = union(enum) {
        scalar: ScalarType,
        vector: struct { scalar: ScalarType, width: VectorWidth },
        resource: ResourceKind,
        resource_typed: struct { kind: ResourceKind, format: ScalarType, width: VectorWidth },
    };
};

pub const Binding = struct {
    space: u32 = 0,
    reg: u32,
};

pub const CbufferSlot = struct {
    reg: u32,
};

pub const Annotation = union(enum) {
    binding: Binding,
    cbuffer: CbufferSlot,
    numthreads: struct { x: u32, y: u32, z: u32 },
    groupshared: struct { size: u32 },
    custom: []const u8,
};

pub const ResourceDecl = struct {
    name: []const u8,
    gpu_type: GpuType,
    binding: Binding,
};

pub const CbufferMember = struct {
    name: []const u8,
    scalar_type: ScalarType,
    vector_width: VectorWidth,
    slot: CbufferSlot,
};

pub const EntryDecl = struct {
    name: []const u8,
    x_param: []const u8,
    y_param: []const u8,
    body_lines: std.ArrayList([]const u8),
    numthreads: struct { x: u32, y: u32, z: u32 },
};

pub const GpuKernel = struct {
    name: []const u8,
    resources: std.ArrayList(ResourceDecl),
    cbuffer_members: std.ArrayList(CbufferMember),
    entries: std.ArrayList(EntryDecl),
    globals_lines: std.ArrayList([]const u8),
};

pub const GpuModule = struct {
    allocator: Allocator,
    kernels: std.ArrayList(GpuKernel),

    pub fn deinit(self: *GpuModule) void {
        for (self.kernels.items) |*k| {
            k.resources.deinit();
            k.cbuffer_members.deinit();
            for (k.entries.items) |*e| {
                for (e.body_lines.items) |line| self.allocator.free(line);
                e.body_lines.deinit();
            }
            k.entries.deinit();
            for (k.globals_lines.items) |line| self.allocator.free(line);
            k.globals_lines.deinit();
        }
        self.kernels.deinit();
    }
};
