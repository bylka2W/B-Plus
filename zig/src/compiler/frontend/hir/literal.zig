const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");

pub const SymbolId = ids.SymbolId;

pub const HirLiteral = union(enum) {
    int: i64,
    float: f64,
    string: SymbolId,
    boolean: bool,

    pub fn format(self: HirLiteral, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |s| try writer.print("\"str({d})\"", .{s.index}),
            .boolean => |v| try writer.print("{s}", .{if (v) "true" else "false"}),
        }
    }
};
