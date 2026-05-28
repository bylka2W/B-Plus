const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const source = try std.fs.cwd().readFileAlloc(allocator, "stress/syntax/t018.bp", 1024 * 1024);
    std.debug.print("Source ({d} bytes): {s}\n", .{ source.len, source });
    
    var t = tokenizer.Tokenizer.init(source, allocator);
    var tokens = std.ArrayList(tokenizer.Token).init(allocator);
    var i: usize = 0;
    while (true) {
        const tok = t.next();
        try tokens.append(tok);
        const text = t.tokenText(tok);
        std.debug.print("  token {d}: {s} = '{s}'\n", .{ i, @tagName(tok.ttype), text });
        i += 1;
        if (tok.ttype == .eof or tok.ttype == .invalid) break;
    }
    
    var p = parser_mod.Parser.init(tokens.items, source, allocator);
    const prog = p.parseProgram() catch |err| {
        std.debug.print("\nParse error: {}\n", .{err});
        std.debug.print("  at pos {d}, token: '{s}'\n", .{ p.pos, if (p.pos < tokens.items.len) @tagName(tokens.items[p.pos].ttype) else "eof" });
        return;
    };
    std.debug.print("\nParsed OK! Entry: {}, States: {d}\n", .{ prog.entry != null, prog.states.items.len });
}