const std = @import("std");
const lib = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: bpc <file.bp> [--llvm]\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        std.debug.print("bpc 0.1.0 (Zig backend)\n", .{});
        return;
    }
    var mode: u8 = 0;
    var filepath: []const u8 = args[1];
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--llvm")) {
        mode = 1;
    } else if (args.len >= 2 and std.mem.eql(u8, args[1], "--llvm")) {
        mode = 1;
        filepath = args[2];
    }
    const source = try std.fs.cwd().readFileAlloc(allocator, filepath, 1024 * 1024);
    defer allocator.free(source);

    const output = try lib.generate(source, allocator, mode);

    const out_path = if (mode == 1) "output.ll" else "output.zig";
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output });
    std.debug.print("Generated {s}\n", .{out_path});
}
