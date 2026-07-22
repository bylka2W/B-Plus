const std = @import("std");
const impl = @import("tests/unit/test_bir_to_mir_e2e.zig");
pub fn main() !void {
    try impl.main();
}
