const std = @import("std");

// ── Runtime identifiers ──

pub const ResourceId = u64;

pub const QueueType = enum { compute, graphics };

// ── Binding types ──

pub const BindingKind = enum { srv, uav, cbv, sampler };

/// Root signature binding type (duplicate of BindingKind for API clarity)
pub const BindType = enum { srv, uav, cbv, sampler };

/// Single slot in a root signature layout
pub const BindSlot = struct {
    register: u32,
    space: u32,
    bind_type: BindType,
};

/// A compiled layout: list of binding slots
pub const BindLayout = struct {
    slots: []const BindSlot,
};

/// Unique identifier for a binding point (register + space + kind)
pub const BindingKey = struct {
    reg: u32,
    space: u32,
    kind: BindingKind,
};

pub const DispatchGrid = struct { x: u32, y: u32, z: u32 };

pub const BarrierDesc = struct {
    resource_id: ResourceId,
    state_before: u32,
    state_after: u32,
};

pub const BindEntry = struct {
    resource_id: ResourceId,
    key: BindingKey,
};

pub const BindGroup = struct {
    entries: []const BindEntry = &.{},
};

// ── Resource types ──

pub const ResourceFormat = enum(u32) {
    r32g32b32a32_float = 2,
    r32g32b32a32_uint = 3,
    r32g32b32a32_sint = 4,
    r32g32b32_float = 6,
    r32g32b32_uint = 7,
    r32g32b32_sint = 8,
    r16g16b16a16_float = 10,
    r16g16b16a16_unorm = 11,
    r16g16b16a16_uint = 13,
    r16g16b16a16_snorm = 14,
    r16g16b16a16_sint = 15,
    r32g32_float = 16,
    r32g32_uint = 17,
    r32g32_sint = 18,
    r32g8x24_typeless = 19,
    r10g10b10a2_unorm = 24,
    r11g11b10_float = 26,
    r8g8b8a8_unorm = 28,
    r8g8b8a8_unorm_srgb = 29,
    r8g8b8a8_uint = 30,
    r8g8b8a8_snorm = 31,
    r8g8b8a8_sint = 32,
    r16g16_float = 34,
    r16g16_unorm = 35,
    r16g16_uint = 36,
    r16g16_snorm = 37,
    r16g16_sint = 38,
    r32_float = 41,
    r32_uint = 42,
    r32_sint = 43,
    r8g8_unorm = 49,
    r8g8_uint = 50,
    r8g8_snorm = 51,
    r8g8_sint = 52,
    r16_float = 54,
    r16_unorm = 55,
    r16_uint = 56,
    r16_snorm = 57,
    r16_sint = 58,
    r8_unorm = 61,
    r8_uint = 62,
    r8_snorm = 63,
    r8_sint = 64,

    pub fn toDXGI(f: ResourceFormat) u32 {
        return @intFromEnum(f);
    }
};

pub const ResourceState = enum {
    common,
    unordered_access,
    non_pixel_shader_resource,
    pixel_shader_resource,
    copy_source,
    copy_dest,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: ResourceFormat = .r16g16b16a16_float,
    mip_levels: u32 = 1,
    array_size: u32 = 1,
};

pub const BufferDesc = struct {
    size: u64 = 0,
    stride: u32 = 0,
    elements: u32 = 0,
};

pub const ResourceDesc = union(enum) {
    texture2d: TextureDesc,
    buffer: BufferDesc,
    sampler: void,
};

pub const ResourceClass = enum {
    color,
    depth,
    motion,
    exposure,
    reactive,
    compositing,
    optical_flow,
    history,
};

pub const ShaderKey = struct {
    source: []const u8,
    entry: []const u8 = "main",
};

pub const PipelineKey = struct {
    shader: ShaderKey,
    layout: []const BindingKey = &.{},
};
