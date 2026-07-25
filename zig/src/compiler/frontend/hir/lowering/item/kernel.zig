const std = @import("std");
const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const ast = @import("../../../ast.zig");
const hir_item = @import("../../item.zig");
const HirItemKind = hir_item.HirItem.HirItemKind;

pub fn lowerKernelItem(self: *HirLowering, kernel: ast.KernelDecl) LowerError!ItemId {
    var dispatch_x: u32 = 1;
    var dispatch_y: u32 = 1;
    var dispatch_z: u32 = 1;

    for (kernel.annotations.items) |ann| {
        const ann_name = std.mem.trim(u8, ann.name, " \t\r\n");
        if (std.mem.startsWith(u8, ann_name, "numthreads")) {
            if (ann.value) |val| {
                var parts = std.mem.splitScalar(u8, val, ',');
                if (parts.next()) |x_str| {
                    dispatch_x = std.fmt.parseInt(u32, std.mem.trim(u8, x_str, " \t"), 10) catch 1;
                }
                if (parts.next()) |y_str| {
                    dispatch_y = std.fmt.parseInt(u32, std.mem.trim(u8, y_str, " \t"), 10) catch 1;
                }
                if (parts.next()) |z_str| {
                    dispatch_z = std.fmt.parseInt(u32, std.mem.trim(u8, z_str, " \t"), 10) catch 1;
                }
            }
        }
    }

    const entries = try self.hir.allocator().alloc(HirItemKind.KernelEntry, 0);
    const bindings = try self.hir.allocator().alloc(HirItemKind.KernelBinding, 0);

    return self.hir.addItem(.{
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
        .kind = .{ .kernel_item = .{
            .name = .INVALID,
            .def_id = .INVALID,
            .attrs = &.{},
            .entries = entries,
            .bindings = bindings,
            .dispatch = .{ .x = dispatch_x, .y = dispatch_y, .z = dispatch_z },
            .visibility = .public,
        } },
    });
}
