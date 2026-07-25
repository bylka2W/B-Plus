const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../../frontend/ast.zig");
const hir = @import("../node.zig");
const common = @import("common.zig");

pub fn lowerKernel(allocator: Allocator, kernel: ast.KernelDecl, sema_ctx: common.SemaContext) !hir.HirKernel {
    _ = sema_ctx;

    const entries = std.ArrayList(hir.HirEntry).init(allocator);
    const bindings = std.ArrayList(hir.HirBinding).init(allocator);

    for (kernel.annotations.items) |ann| {
        const ann_name = std.mem.trim(u8, ann.name, " \t\r\n");
        if (std.mem.startsWith(u8, ann_name, "numthreads")) {
            _ = &ann_name;
        }
    }

    return .{
        .name = try allocator.dupe(u8, kernel.name),
        .entries = entries,
        .bindings = bindings,
        .numthreads = .{ .x = 1, .y = 1, .z = 1 },
        .context_vars = std.ArrayList(hir.HirKernel.HirContextVar).init(allocator),
    };
}
