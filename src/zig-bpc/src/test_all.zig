const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");
const gen_zig = @import("gen_zig.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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
        _ = gen.generate(prog) catch |err| {
            std.debug.print("FAIL t{d:0>3}: gen error {}\n", .{ i, err });
            fail += 1;
            continue;
        };

        std.debug.print("PASS t{d:0>3}\n", .{i});
        pass += 1;
    }
    std.debug.print("\n{d}/{d} passed, {d} failed\n", .{ pass, pass + fail, fail });
    if (fail > 0) std.process.exit(1);
}
