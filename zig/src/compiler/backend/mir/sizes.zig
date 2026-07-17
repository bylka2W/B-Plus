const std = @import("std");
const d3d = @import("src/render/d3d12_bindings.zig");
pub fn main() void {
    std.debug.print("RESOURCE_BARRIER: {d}\n", .{@sizeOf(d3d.D3D12_RESOURCE_BARRIER)});
    std.debug.print("TRANSITION: {d}\n", .{@sizeOf(d3d.D3D12_RESOURCE_TRANSITION_BARRIER)});
    std.debug.print("UAV_BARRIER: {d}\n", .{@sizeOf(d3d.D3D12_RESOURCE_UAV_BARRIER)});
    std.debug.print("GPU_DESC_HANDLE: {d}\n", .{@sizeOf(d3d.D3D12_GPU_DESCRIPTOR_HANDLE)});
    std.debug.print("CPU_DESC_HANDLE: {d}\n", .{@sizeOf(d3d.D3D12_CPU_DESCRIPTOR_HANDLE)});
    std.debug.print("COMMAND_QUEUE_DESC: {d}\n", .{@sizeOf(d3d.D3D12_COMMAND_QUEUE_DESC)});
    std.debug.print("MESSAGE: {d}\n", .{@sizeOf(d3d.D3D12_MESSAGE)});
    std.debug.print("IUnknownVtbl: {d}\n", .{@sizeOf(d3d.IUnknownVtbl)});
    std.debug.print("D3D12BaseVtbl: {d}\n", .{@sizeOf(d3d.D3D12BaseVtbl)});
    std.debug.print("CommandQueueVtbl: {d}\n", .{@sizeOf(d3d.ID3D12CommandQueueVtbl)});
    std.debug.print("GraphicsCmdListVtbl: {d}\n", .{@sizeOf(d3d.ID3D12GraphicsCommandListVtbl)});
    std.debug.print("DeviceVtbl: {d}\n", .{@sizeOf(d3d.ID3D12DeviceVtbl)});
    std.debug.print("HeapVtbl: {d}\n", .{@sizeOf(d3d.ID3D12DescriptorHeapVtbl)});
    std.debug.print("FenceVtbl: {d}\n", .{@sizeOf(d3d.ID3D12FenceVtbl)});
    std.debug.print("ResourceVtbl: {d}\n", .{@sizeOf(d3d.ID3D12ResourceVtbl)});
    std.debug.print("AllocatorVtbl: {d}\n", .{@sizeOf(d3d.ID3D12CommandAllocatorVtbl)});
    std.debug.print("InfoQueueVtbl: {d}\n", .{@sizeOf(d3d.ID3D12InfoQueueVtbl)});
}
