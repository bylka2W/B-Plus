const std = @import("std");
const green_node_mod = @import("green_node.zig");
const green_token_mod = @import("green_token.zig");
const green_tree_mod = @import("green_tree.zig");

pub const GreenNode = green_node_mod.GreenNode;
pub const GreenToken = green_token_mod.GreenToken;
pub const SyntaxKind = green_node_mod.SyntaxKind;
pub const GreenTree = green_tree_mod.GreenTree;

pub const GreenBuilder = struct {
    tree: *GreenTree,
    children: std.ArrayList(GreenNode.ChildSlot),
    errors: std.ArrayList(GreenBuilderError),

    pub const GreenBuilderError = struct {
        message: []const u8,
        span_start: u32,
        span_end: u32,
    };

    pub fn init(tree: *GreenTree) GreenBuilder {
        return .{
            .tree = tree,
            .children = std.ArrayList(GreenNode.ChildSlot).init(tree.allocator),
            .errors = std.ArrayList(GreenBuilderError).init(tree.allocator),
        };
    }

    pub fn deinit(self: *GreenBuilder) void {
        self.children.deinit();
        self.errors.deinit();
    }

    pub fn pushToken(self: *GreenBuilder, kind: SyntaxKind, text: []const u8, start: u32, end: u32) !void {
        const tok = GreenToken.init(kind, text, start, end);
        try self.children.append(.{ .token = tok });
    }

    pub fn pushGreenToken(self: *GreenBuilder, tok: GreenToken) !void {
        try self.children.append(.{ .token = tok });
    }

    pub fn pushNode(self: *GreenBuilder, node: *GreenNode) !void {
        try self.children.append(.{ .node = node });
    }

    pub fn pushTrivia(self: *GreenBuilder, kind: SyntaxKind, text: []const u8, start: u32, end: u32) !void {
        const tok = GreenToken.init(kind, text, start, end);
        try self.children.append(.{ .trivia = tok });
    }

    pub fn pushError(self: *GreenBuilder, message: []const u8, start: u32, end: u32) !void {
        try self.errors.append(.{ .message = message, .span_start = start, .span_end = end });
    }

    pub fn finish(self: *GreenBuilder, kind: SyntaxKind) !*GreenNode {
        const node = try self.tree.allocNode(kind, self.children.items);
        return node;
    }

    pub fn finishWithErrors(self: *GreenBuilder, kind: SyntaxKind) !struct { node: *GreenNode, errors: []const GreenBuilderError } {
        const node = try self.finish(kind);
        return .{ .node = node, .errors = self.errors.items };
    }

    pub fn hasErrors(self: *const GreenBuilder) bool {
        return self.errors.items.len > 0;
    }

    pub fn childCount(self: *const GreenBuilder) u32 {
        return @intCast(self.children.items.len);
    }

    pub fn clear(self: *GreenBuilder) void {
        self.children.clearRetainingCapacity();
        self.errors.clearRetainingCapacity();
    }

    pub fn buildToken(self: *GreenTree, kind: SyntaxKind, text: []const u8, start: u32, end: u32) !*GreenNode {
        return self.tree.allocToken(kind, text, start, end);
    }

    pub fn buildMissing(self: *GreenTree, kind: SyntaxKind) !*GreenNode {
        return self.tree.allocMissing(kind);
    }
};
