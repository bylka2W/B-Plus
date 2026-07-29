const std = @import("std");
const builtin = @import("builtin");

pub const LinkMode = enum {
    exe,
    dll,
};

pub const LinkOptions = struct {
    obj_path: []const u8,
    output_path: []const u8,
    entry: []const u8 = "plan",
    subsystem: []const u8 = "console",
    mode: LinkMode = .exe,
    lib_dirs: []const []const u8 = &.{},
    libs: []const []const u8 = &.{},
    extra_objs: []const []const u8 = &.{},
};

pub fn link(allocator: std.mem.Allocator, options: LinkOptions) !void {
    if (builtin.os.tag == .windows) {
        return @import("windows.zig").linkWithLld(allocator, options);
    }
    return error.UnsupportedPlatform;
}
