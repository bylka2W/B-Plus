const std = @import("std");

pub const HirLiteral = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,

    pub fn format(self: HirLiteral, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .boolean => |v| try writer.print("{s}", .{if (v) "true" else "false"}),
        }
    }
};
