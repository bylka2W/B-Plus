const std = @import("std");
const green_token_mod = @import("../green/green_token.zig");
const green_node_mod = @import("../green/green_node.zig");

pub const TokenKind = green_token_mod.TokenKind;
pub const SyntaxKind = green_node_mod.SyntaxKind;
pub const GreenToken = green_token_mod.GreenToken;
pub const GreenNode = green_node_mod.GreenNode;

pub const SyntaxToken = struct {
    green: *const GreenToken,
    offset: u32,

    pub fn init(green: *const GreenToken, offset: u32) SyntaxToken {
        return .{ .green = green, .offset = offset };
    }

    pub fn kind(self: SyntaxToken) SyntaxKind {
        return self.green.kind;
    }

    pub fn text(self: SyntaxToken) []const u8 {
        return self.green.text;
    }

    pub fn spanStart(self: SyntaxToken) u32 {
        return self.green.span_start;
    }

    pub fn spanEnd(self: SyntaxToken) u32 {
        return self.green.span_end;
    }

    pub fn relativeStart(self: SyntaxToken) u32 {
        return self.green.span_start -| self.offset;
    }

    pub fn relativeEnd(self: SyntaxToken) u32 {
        return self.green.span_end -| self.offset;
    }

    pub fn len(self: SyntaxToken) u32 {
        return self.green.len();
    }

    pub fn isTrivia(self: SyntaxToken) bool {
        return self.green.is_trivia();
    }

    pub fn isError(self: SyntaxToken) bool {
        return self.green.is_error();
    }
};

pub const SyntaxNode = struct {
    green: *const GreenNode,
    offset: u32,

    pub fn init(green: *const GreenNode, offset: u32) SyntaxNode {
        return .{ .green = green, .offset = offset };
    }

    pub fn kind(self: SyntaxNode) SyntaxKind {
        return self.green.kind;
    }

    pub fn spanStart(self: SyntaxNode) u32 {
        return self.green.span_start;
    }

    pub fn spanEnd(self: SyntaxNode) u32 {
        return self.green.span_end;
    }

    pub fn relativeStart(self: SyntaxNode) u32 {
        return self.green.span_start -| self.offset;
    }

    pub fn relativeEnd(self: SyntaxNode) u32 {
        return self.green.span_end -| self.offset;
    }

    pub fn len(self: SyntaxNode) u32 {
        return self.green.len();
    }

    pub fn childCount(self: SyntaxNode) u32 {
        return self.green.childCount();
    }

    pub fn childTokens(self: SyntaxNode) ChildTokenIterator {
        return .{ .green = self.green, .index = 0, .offset = self.offset };
    }

    pub fn childNodes(self: SyntaxNode) ChildNodeIterator {
        return .{ .green = self.green, .index = 0, .offset = self.offset };
    }

    pub fn allChildren(self: SyntaxNode) ChildIterator {
        return .{ .green = self.green, .index = 0, .offset = self.offset };
    }

    pub fn firstChild(self: SyntaxNode) ?SyntaxElement {
        const green_child = self.green.firstChild() orelse return null;
        return .{
            .data = green_child,
            .offset = self.offset,
        };
    }

    pub fn lastChild(self: SyntaxNode) ?SyntaxElement {
        const green_child = self.green.lastChild() orelse return null;
        return .{
            .data = green_child,
            .offset = self.offset,
        };
    }

    pub fn childAt(self: SyntaxNode, idx: u32) ?SyntaxElement {
        const green_child = self.green.child(idx) orelse return null;
        return .{
            .data = green_child,
            .offset = self.offset,
        };
    }

    pub const ChildTokenIterator = struct {
        green: *const GreenNode,
        index: u32,
        offset: u32,

        pub fn next(self: *ChildTokenIterator) ?SyntaxToken {
            while (self.index < self.green.children.len) {
                const idx = self.index;
                self.index += 1;
                switch (self.green.children[idx]) {
                    .token => |*t| return SyntaxToken.init(t, self.offset),
                    .trivia => |*t| return SyntaxToken.init(t, self.offset),
                    .node => {},
                }
            }
            return null;
        }
    };

    pub const ChildNodeIterator = struct {
        green: *const GreenNode,
        index: u32,
        offset: u32,

        pub fn next(self: *ChildNodeIterator) ?SyntaxNode {
            while (self.index < self.green.children.len) {
                const idx = self.index;
                self.index += 1;
                if (self.green.children[idx] == .node) {
                    return SyntaxNode.init(self.green.children[idx].node, self.offset);
                }
            }
            return null;
        }
    };

    pub const ChildIterator = struct {
        green: *const GreenNode,
        index: u32,
        offset: u32,

        pub fn next(self: *ChildIterator) ?SyntaxElement {
            while (self.index < self.green.children.len) {
                const idx = self.index;
                self.index += 1;
                switch (self.green.children[idx]) {
                    .token => |*t| {
                        if (!t.is_trivia()) {
                            return .{ .token = SyntaxToken.init(t, self.offset) };
                        }
                    },
                    .trivia => {},
                    .node => |n| {
                        return .{ .node = SyntaxNode.init(n, self.offset) };
                    },
                }
            }
            return null;
        }
    };
};

pub const SyntaxElement = union(enum) {
    node: SyntaxNode,
    token: SyntaxToken,

    pub fn kind(self: SyntaxElement) SyntaxKind {
        return switch (self) {
            .node => |n| n.kind(),
            .token => |t| t.kind(),
        };
    }

    pub fn spanStart(self: SyntaxElement) u32 {
        return switch (self) {
            .node => |n| n.spanStart(),
            .token => |t| t.spanStart(),
        };
    }

    pub fn spanEnd(self: SyntaxElement) u32 {
        return switch (self) {
            .node => |n| n.spanEnd(),
            .token => |t| t.spanEnd(),
        };
    }

    pub fn len(self: SyntaxElement) u32 {
        return switch (self) {
            .node => |n| n.len(),
            .token => |t| t.len(),
        };
    }

    pub fn asNode(self: SyntaxElement) ?SyntaxNode {
        return switch (self) {
            .node => |n| n,
            .token => null,
        };
    }

    pub fn asToken(self: SyntaxElement) ?SyntaxToken {
        return switch (self) {
            .node => null,
            .token => |t| t,
        };
    }

    pub fn isNode(self: SyntaxElement) bool {
        return self == .node;
    }

    pub fn isToken(self: SyntaxElement) bool {
        return self == .token;
    }
};
