const std = @import("std");
const frontend_test = @import("src/compiler/frontend/frontend_test.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const src = "state Main { entry { print(totally_nonexistent_var) } }";
    const result = try frontend_test.typeCheckSource(src, allocator);
    const count = result.errors.count();
    std.debug.print("errors count={}\n", .{count});
}
