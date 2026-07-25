const std = @import("std");
const testing = std.testing;
const lexer_mod = @import("syntax/lexer/scanner.zig");
const token_stream_mod = @import("syntax/token/token_stream.zig");
const green_tree_mod = @import("syntax/green/green_tree.zig");
const parser_mod = @import("syntax/parser/parser.zig");
const syntax_node_mod = @import("syntax/red/syntax_node.zig");
const Lexer = lexer_mod.Lexer;
const TokenStream = token_stream_mod.TokenStream;
const GreenTree = green_tree_mod.GreenTree;
const Parser = parser_mod.Parser;
const SyntaxNode = syntax_node_mod.SyntaxNode;

test "debug: parser tree" {
    const allocator = testing.allocator;
    const source = "fn main() {\n    return 42;\n}\n";
    var lexer = Lexer.init(source, 0, allocator);
    defer lexer.deinit();
    const tokens = try lexer.lex();
    var stream = TokenStream.init(allocator);
    defer stream.deinit();
    for (tokens.items) |tok| {
        try stream.append(tok);
    }
    var green = GreenTree.init(allocator);
    defer green.deinit();
    var parser = Parser.init(&stream, allocator);
    defer parser.deinit();
    const green_root = try parser.parse(&green);
    std.debug.print("root kind: {s}\n", .{@tagName(green_root.kind)});
    std.debug.print("root children len: {d}\n", .{green_root.children.len});
    for (green_root.children, 0..) |child, i| {
        switch (child) {
            .node => |n| std.debug.print("  [{d}] node kind={s} span=[{d}..{d}]\n", .{ i, @tagName(n.kind), n.span_start, n.span_end }),
            .token => |t| std.debug.print("  [{d}] token kind={s} text=\"{s}\"\n", .{ i, @tagName(t.kind), t.text }),
            .trivia => |t| std.debug.print("  [{d}] trivia kind={s}\n", .{ i, @tagName(t.kind) }),
        }
    }
}
