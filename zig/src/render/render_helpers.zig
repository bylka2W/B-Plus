const gpu_types = @import("../compiler/gpu/gpu_types.zig");

pub fn dispatch2D(width: u32, height: u32) gpu_types.DispatchGrid {
    return .{
        .x = (width + 7) / 8,
        .y = (height + 7) / 8,
        .z = 1,
    };
}

pub fn makeBindGroup(entries: []const gpu_types.BindEntry) gpu_types.BindGroup {
    return .{ .entries = entries };
}
