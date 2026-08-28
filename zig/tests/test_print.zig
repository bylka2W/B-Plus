const std = @import("std");
const testing = std.testing;

test "print-test" {
    std.debug.print("Hello world\n", .{});
    testing.expect(true);
}
