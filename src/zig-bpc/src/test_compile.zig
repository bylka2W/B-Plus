const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");
const gen_zig = @import("gen_zig.zig");
const Child = std.process.Child;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const zig_path = "C:\\tools\\zig\\zig-windows-x86_64-0.14.0\\zig.exe";

    var pass: usize = 0;
    var fail: usize = 0;
    var i: usize = 1;
    while (i <= 25) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "stress/syntax/t{d:0>3}.bp", .{i}) catch unreachable;

        const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            std.debug.print("FAIL t{d:0>3}: read error {}\n", .{ i, err });
            fail += 1;
            continue;
        };

        const tokens = tokenizer.tokenizeFull(source, allocator) catch |err| {
            std.debug.print("FAIL t{d:0>3}: tokenize error {}\n", .{ i, err });
            fail += 1;
            continue;
        };

        var p = parser_mod.Parser.init(tokens, source, allocator);
        const prog = p.parseProgram() catch |err| {
            std.debug.print("FAIL t{d:0>3}: parse error {}\n", .{ i, err });
            fail += 1;
            continue;
        };

        var gen = gen_zig.Generator.init(allocator);
        const output = gen.generate(prog) catch |err| {
            std.debug.print("FAIL t{d:0>3}: gen error {}\n", .{ i, err });
            fail += 1;
            continue;
        };

        try std.fs.cwd().writeFile(.{ .sub_path = "output.zig", .data = output });

        var proc = Child.init(&.{ zig_path, "build-exe", "output.zig", "--name", "out", "--cache-dir", "src\\zig-bpc\\zig-cache", "--global-cache-dir", "src\\zig-bpc\\zig-global-cache" }, allocator);
        proc.stdout_behavior = .Ignore;
        proc.stderr_behavior = .Ignore;
        const term = try proc.spawnAndWait();
        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    std.debug.print("PASS t{d:0>3}\n", .{i});
                    pass += 1;
                } else {
                    std.debug.print("FAIL t{d:0>3}: zig compile exit {d}\n", .{ i, code });
                    fail += 1;
                }
            },
            else => {
                std.debug.print("FAIL t{d:0>3}: zig compile terminated\n", .{i});
                fail += 1;
            },
        }
    }
    std.debug.print("\n{d}/{d} passed, {d} failed\n", .{ pass, pass + fail, fail });
    if (fail > 0) std.process.exit(1);
}
