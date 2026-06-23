const std = @import("std");

pub const QueueType = enum(u8) {
    compute,
    graphics,
};

pub const ShaderStage = enum(u8) {
    compute,
};

pub const BindType = enum(u8) {
    srv,
    uav,
    cbv,
    sampler,
};

pub const BindSlot = struct {
    register: u32,
    space: u32,
    bind_type: BindType,
    num_descriptors: u32 = 1,
};

pub const BindLayout = struct {
    slots: []const BindSlot,
};

pub const BindingKey = struct {
    reg: u32,
    space: u32,
    kind: BindType,
};

/// Deterministic slot index within a unified CBV_SRV_UAV descriptor heap.
/// Layout (for descriptor heap ~1024 slots):
///   0..255    SRV (t registers)
///   256..511  UAV (u registers)
///   512..767  CBV (b registers)
/// Within each band: slot = base + reg + (space << 5)
pub fn slotIndex(key: BindingKey) u32 {
    const band_base: u32 = switch (key.kind) {
        .srv => 0,
        .uav => 256,
        .cbv => 512,
        .sampler => 0,
    };
    return band_base + key.reg + (key.space << 5);
}

pub const ShaderKey = struct {
    source: []const u8,
    entry: []const u8 = "main",
    target: []const u8 = "cs_5_1",
    compile_flags: u32 = 0,
};

pub const PipelineKey = struct {
    shader: ShaderKey,
    layout: BindLayout,
    compiled_bytecode: ?[]const u8 = null,
};

pub const ResourceType = enum(u8) {
    buffer,
    texture2d,
    sampler,
};

pub const ResourceFormat = enum(u8) {
    unknown,
    r32_float,
    r32g32_float,
    r32g32b32a32_float,
    r8_unorm,
    r8g8b8a8_unorm,
    r16_float,
    r16g16_float,
    r16g16b16a16_float,

    pub fn toDXGI(fmt: ResourceFormat) u32 {
        return switch (fmt) {
            .unknown => 0,
            .r32_float => 41,
            .r32g32_float => 16,
            .r32g32b32a32_float => 2,
            .r8_unorm => 61,
            .r8g8b8a8_unorm => 28,
            .r16_float => 54,
            .r16g16_float => 34,
            .r16g16b16a16_float => 10,
        };
    }
};

pub const BufferDesc = struct {
    size: u64,
    stride: u64 = 0,
    elements: u32 = 0,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: ResourceFormat,
    mip_levels: u32 = 1,
};

pub const ResourceDesc = union(enum) {
    buffer: BufferDesc,
    texture2d: TextureDesc,
    sampler: void,
};

pub const ResourceId = u64;

pub const BindEntry = struct {
    key: BindingKey,
    resource_id: ResourceId,
    subresource: u32 = 0,
};

pub const BindGroup = struct {
    entries: []const BindEntry,
};

pub const DispatchGrid = struct {
    x: u32,
    y: u32,
    z: u32 = 1,
};

pub const DispatchDesc = struct {
    pipeline: PipelineKey,
    grid: DispatchGrid,
    bindings: BindGroup,
};

pub const BarrierType = enum(u8) {
    transition,
    uav,
};

pub const ResourceState = enum(u8) {
    common,
    unordered_access,
    non_pixel_shader_resource,
    pixel_shader_resource,
    copy_source,
    copy_dest,
};

pub const BarrierDesc = struct {
    resource_id: ResourceId,
    barrier_type: BarrierType = .transition,
    state_before: ResourceState = .unordered_access,
    state_after: ResourceState = .non_pixel_shader_resource,
};

pub const GPUIRPass = struct {
    id: u32,
    name: []const u8,
    dispatch: DispatchDesc,
    barriers_before: []const BarrierDesc = &.{},
    barriers_after: []const BarrierDesc = &.{},
};
