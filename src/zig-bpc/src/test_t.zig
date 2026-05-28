const std = @import("std");
const tokenizer = @import("tokenizer.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const src = " x++; ";
    std.debug.print("Input: '{s}'\n", .{ src });
    var t = tokenizer.Tokenizer.init(src, allocator);
    var i: usize = 0;
    while (true) {
        const tok = t.next();
        const text = t.tokenText(tok);
        std.debug.print("  tok {d}: {s} = '{s}'\n", .{ i, @tagName(tok.ttype), text });
        i += 1;
        if (tok.ttype == .eof or tok.ttype == .invalid) break;
    }
    std.debug.print("Done ({d} tokens)\n", .{i});
}