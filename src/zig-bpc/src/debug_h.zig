const std = @import("std");
const tokenizer = @import("tokenizer.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const source = try std.fs.cwd().readFileAlloc(allocator, "hello.bp", 1024 * 1024);
    std.debug.print("Source: {s}\n", .{ source });
    std.debug.print("Bytes: ", .{});
    for (source) |c| std.debug.print("'{c}'({d}) ", .{ c, c });
    std.debug.print("\n", .{});
    var t = tokenizer.Tokenizer.init(source, allocator);
    var i: usize = 0;
    while (true) {
        const tok = t.next();
        const text = t.tokenText(tok);
        std.debug.print("  token {d}: {s} = '{s}'\n", .{ i, @tagName(tok.ttype), text });
        i += 1;
        if (tok.ttype == .eof or tok.ttype == .invalid) break;
    }
}