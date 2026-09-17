const std = @import("std");
const LinkOptions = @import("linker.zig").LinkOptions;
const LinkMode = @import("linker.zig").LinkMode;

const lld_link_path = "C:\\Program Files\\LLVM\\bin\\lld-link.exe";

/// Remove a stale output file that a previous crashed/lingering process may still hold.
/// If the file is locked by a running process, terminate that process (by image name)
/// and retry, so `bpc run` never dies with "permission denied" on re-builds.
fn ensureOutputDeletable(output_path: []const u8) void {
    std.fs.cwd().deleteFile(output_path) catch {};
    if (std.fs.cwd().openFile(output_path, .{ .mode = .read_only })) |f| {
        f.close();
        const base = std.fs.path.basename(output_path);
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "taskkill", "/F", "/IM", base, "/T" },
        }) catch {
            std.debug.print("note: could not kill {s} (still running)\n", .{base});
            return;
        };
        std.time.sleep(250 * std.time.ns_per_ms);
        std.fs.cwd().deleteFile(output_path) catch {};
        std.time.sleep(50 * std.time.ns_per_ms);
        std.fs.cwd().deleteFile(output_path) catch {};
    } else |_| {}
}

pub fn linkWithLld(allocator: std.mem.Allocator, options: LinkOptions) !void {
    const lld_exists = blk: {
        const f = std.fs.accessAbsolute(lld_link_path, .{}) catch {
            break :blk false;
        };
        _ = f;
        break :blk true;
    };
    if (!lld_exists) {
        std.debug.print("error: lld-link.exe not found at {s}\n", .{lld_link_path});
        std.debug.print("  Install LLVM or set PATH to include lld-link.exe\n", .{});
        return error.LldNotFound;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = std.ArrayList([]const u8).init(aa);
    try args.append(lld_link_path);
    try args.append(options.obj_path);

    ensureOutputDeletable(options.output_path);
    for (options.extra_objs) |obj| try args.append(obj);
    try args.append(try std.fmt.allocPrint(aa, "-out:{s}", .{options.output_path}));
    try args.append(try std.fmt.allocPrint(aa, "-entry:{s}", .{options.entry}));
    try args.append(try std.fmt.allocPrint(aa, "-subsystem:{s}", .{options.subsystem}));
    try args.append("-nologo");

    if (options.mode == .dll) {
        try args.append("-dll");
    }

    for (options.lib_dirs) |dir| {
        try args.append(try std.fmt.allocPrint(aa, "-libpath:{s}", .{dir}));
    }

    for (options.libs) |lib| {
        try args.append(lib);
    }

    const result = try std.process.Child.run(.{
        .allocator = aa,
        .argv = args.items,
    });

    if (result.stdout.len > 0) {
        std.debug.print("{s}", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    if (result.term != .Exited or result.term.Exited != 0) {
        return error.LinkFailed;
    }
}
