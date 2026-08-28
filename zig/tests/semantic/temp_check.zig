const std = @import("std");
const frontend_test = @import("../../src/compiler/frontend/frontend_test.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const src = "state Main { entry { print(totally_nonexistent_var) } }";
    const result = try frontend_test.typeCheckSource(src, allocator);
    const has_error = result.errors.count() > 0;
    std.debug.print("has_error={}", .{has_error});
}
