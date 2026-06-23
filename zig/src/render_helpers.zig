const gpu_ir = @import("gpu_ir.zig");

pub fn dispatch2D(width: u32, height: u32) gpu_ir.DispatchGrid {
    return .{
        .x = (width + 7) / 8,
        .y = (height + 7) / 8,
        .z = 1,
    };
}

pub fn makeBindGroup(entries: []const gpu_ir.BindEntry) gpu_ir.BindGroup {
    return .{ .entries = entries };
}
