const std = @import("std");
const kind_mod = @import("../kind/syntax_kind.zig");
const green_token = @import("green_token.zig");

pub const SyntaxKind = kind_mod.SyntaxKind;
pub const GreenToken = green_token.GreenToken;

pub const GreenNode = struct {
    kind: SyntaxKind,
    children: []const ChildSlot,
    span_start: u32,
    span_end: u32,

    pub const ChildSlot = union(enum) {
        token: GreenToken,
        node: *GreenNode,
        trivia: GreenToken,
    };

    pub fn init(allocator: std.mem.Allocator, kind: SyntaxKind, children: []const ChildSlot) !*GreenNode {
        var span_start: u32 = std.math.maxInt(u32);
        var span_end: u32 = 0;

        for (children) |ch| {
            const range = switch (ch) {
                .token => |t| .{ t.span_start, t.span_end },
                .node => |n| .{ n.span_start, n.span_end },
                .trivia => |t| .{ t.span_start, t.span_end },
            };
            if (range[0] < span_start) span_start = range[0];
            if (range[1] > span_end) span_end = range[1];
        }

        const node = try allocator.create(GreenNode);
        node.* = .{
            .kind = kind,
            .children = try allocator.dupe(GreenNode.ChildSlot, children),
            .span_start = if (children.len == 0) 0 else span_start,
            .span_end = if (children.len == 0) 0 else span_end,
        };
        return node;
    }

    pub fn tokenOnly(kind: SyntaxKind, start: u32, end: u32) GreenNode {
        return .{
            .kind = kind,
            .children = &.{},
            .span_start = start,
            .span_end = end,
        };
    }

    pub fn childCount(self: *const GreenNode) u32 {
        return @intCast(self.children.len);
    }

    pub fn child(self: *const GreenNode, idx: u32) ?ChildSlot {
        if (idx >= self.children.len) return null;
        return self.children[idx];
    }

    pub fn firstChild(self: *const GreenNode) ?ChildSlot {
        return if (self.children.len > 0) self.children[0] else null;
    }

    pub fn lastChild(self: *const GreenNode) ?ChildSlot {
        return if (self.children.len > 0) self.children[self.children.len - 1] else null;
    }

    pub fn childTokens(self: *const GreenNode) TokenIterator {
        return .{ .node = self, .index = 0, .filter = .token };
    }

    pub fn childNodes(self: *const GreenNode) NodeIterator {
        return .{ .node = self, .index = 0 };
    }

    pub fn allChildren(self: *const GreenNode) []const ChildSlot {
        return self.children;
    }

    pub fn len(self: *const GreenNode) u32 {
        return self.span_end - self.span_start;
    }

    pub fn isMissing(self: *const GreenNode) bool {
        return self.span_start == 0 and self.span_end == 0 and self.children.len == 0;
    }

    pub const TokenIterator = struct {
        node: *const GreenNode,
        index: u32,
        filter: enum { token, trivia },

        pub fn next(self: *TokenIterator) ?GreenToken {
            while (self.index < self.node.children.len) {
                const idx = self.index;
                self.index += 1;
                switch (self.node.children[idx]) {
                    .token => |t| return t,
                    .trivia => |t| {
                        if (self.filter == .trivia) return t;
                    },
                    .node => {},
                }
            }
            return null;
        }
    };

    pub const NodeIterator = struct {
        node: *const GreenNode,
        index: u32,

        pub fn next(self: *NodeIterator) ?*GreenNode {
            while (self.index < self.node.children.len) {
                const idx = self.index;
                self.index += 1;
                if (self.node.children[idx] == .node) {
                    return self.node.children[idx].node;
                }
            }
            return null;
        }
    };
};
