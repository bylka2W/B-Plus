const std = @import("std");
const green_node_mod = @import("green_node.zig");
const green_token_mod = @import("green_token.zig");

pub const GreenNode = green_node_mod.GreenNode;
pub const GreenToken = green_token_mod.GreenToken;
pub const SyntaxKind = green_node_mod.SyntaxKind;

pub const GreenTree = struct {
    allocator: std.mem.Allocator,
    root_node: *GreenNode,
    node_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) GreenTree {
        return .{
            .allocator = allocator,
            .root_node = undefined,
            .node_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *GreenTree) void {
        self.node_arena.deinit();
    }

    pub fn setRoot(self: *GreenTree, node: *GreenNode) void {
        self.root_node = node;
    }

    pub fn root(self: *const GreenTree) *GreenNode {
        return self.root_node;
    }

    pub fn allocNode(self: *GreenTree, kind: SyntaxKind, children: []const GreenNode.ChildSlot) !*GreenNode {
        return GreenNode.init(self.node_arena.allocator(), kind, children);
    }

    pub fn allocToken(self: *GreenTree, kind: SyntaxKind, text: []const u8, start: u32, end: u32) !*GreenNode {
        const tok = GreenToken.init(kind, text, start, end);
        const slot = GreenNode.ChildSlot{ .token = tok };
        return self.allocNode(kind, &.{slot});
    }

    pub fn allocMissing(self: *GreenTree, kind: SyntaxKind) !*GreenNode {
        return self.allocNode(kind, &.{});
    }

    pub fn dump(self: *const GreenTree, writer: anytype) !void {
        try self.dumpNode(self.root_node, 0, writer);
    }

    fn dumpNode(self: *const GreenTree, node: *const GreenNode, indent: u32, writer: anytype) !void {
        for (0..indent) |_| {
            try writer.writeAll("  ");
        }
        try writer.print("{s} [{d}..{d}]\n", .{
            @tagName(node.kind),
            node.span_start,
            node.span_end,
        });

        for (node.children) |child| {
            switch (child) {
                .token => |t| {
                    for (0..indent + 1) |_| {
                        try writer.writeAll("  ");
                    }
                    try writer.print("token: {s} \"{s}\"\n", .{
                        @tagName(t.kind),
                        t.text,
                    });
                },
                .node => |n| {
                    try self.dumpNode(n, indent + 1, writer);
                },
                .trivia => |t| {
                    for (0..indent + 1) |_| {
                        try writer.writeAll("  ");
                    }
                    try writer.print("trivia: {s}\n", .{@tagName(t.kind)});
                },
            }
        }
    }

    pub fn nodeCount(self: *const GreenTree) u32 {
        return self.countNodes(self.root_node);
    }

    fn countNodes(self: *const GreenTree, node: *const GreenNode) u32 {
        var count: u32 = 1;
        for (node.children) |child| {
            if (child == .node) {
                count += self.countNodes(child.node);
            }
        }
        return count;
    }

    pub fn tokenCount(self: *const GreenTree) u32 {
        return self.countTokens(self.root_node);
    }

    fn countTokens(self: *const GreenTree, node: *const GreenNode) u32 {
        var count: u32 = 0;
        for (node.children) |child| {
            switch (child) {
                .token => count += 1,
                .node => count += self.countTokens(child.node),
                .trivia => {},
            }
        }
        return count;
    }
};
