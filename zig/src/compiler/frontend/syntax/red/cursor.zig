const std = @import("std");
const syntax_node_mod = @import("syntax_node.zig");

pub const SyntaxNode = syntax_node_mod.SyntaxNode;
pub const SyntaxToken = syntax_node_mod.SyntaxToken;
pub const SyntaxElement = syntax_node_mod.SyntaxElement;
pub const SyntaxKind = syntax_node_mod.SyntaxKind;

pub const Cursor = struct {
    position: u32,
    current: ?SyntaxElement,

    pub fn atNode(root: SyntaxNode) Cursor {
        return .{
            .position = 0,
            .current = root.firstChild(),
        };
    }

    pub fn next(self: *Cursor) ?SyntaxElement {
        const current = self.current orelse return null;
        self.advanceToNext(current);
        return current;
    }

    pub fn peek(self: *const Cursor) ?SyntaxElement {
        return self.current;
    }

    pub fn advance(self: *Cursor) void {
        if (self.current) |current| {
            self.advanceToNext(current);
        }
    }

    pub fn goToFirstChild(self: *Cursor) bool {
        if (self.current) |current| {
            if (current.asNode()) |node| {
                if (node.firstChild()) |child| {
                    self.current = child;
                    self.position += 1;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn goToParent(self: *Cursor) bool {
        _ = self;
        return false;
    }

    pub fn goToNextSibling(self: *Cursor) bool {
        if (self.current) |current| {
            const parent = self.findParent(current) orelse return false;
            const parent_node = parent.asNode() orelse return false;

            var found_current = false;
            var iter = parent_node.childTokens();
            while (iter.next()) |tok| {
                if (found_current) {
                    self.current = .{ .token = tok };
                    self.position += 1;
                    return true;
                }
                if (tok.spanStart() == current.spanStart() and tok.spanEnd() == current.spanEnd()) {
                    found_current = true;
                }
            }

            var node_iter = parent_node.childNodes();
            while (node_iter.next()) |node| {
                if (found_current) {
                    self.current = .{ .node = node };
                    self.position += 1;
                    return true;
                }
                if (node.spanStart() == current.spanStart() and node.spanEnd() == current.spanEnd()) {
                    found_current = true;
                }
            }
        }
        return false;
    }

    pub fn findChildByKind(self: *Cursor, kind: SyntaxKind) ?SyntaxElement {
        if (self.current) |current| {
            if (current.asNode()) |node| {
                var iter = node.childNodes();
                while (iter.next()) |child| {
                    if (child.kind() == kind) return .{ .node = child };
                }
                var tok_iter = node.childTokens();
                while (tok_iter.next()) |tok| {
                    if (@intFromEnum(tok.kind()) == @intFromEnum(kind)) return .{ .token = tok };
                }
            }
        }
        return null;
    }

    pub fn at(self: *const Cursor, kind: SyntaxKind) bool {
        if (self.current) |current| {
            return current.kind() == kind;
        }
        return false;
    }

    pub fn atTokenKind(self: *const Cursor, kind: syntax_node_mod.TokenKind) bool {
        if (self.current) |current| {
            if (current.asToken()) |tok| {
                return tok.kind() == kind;
            }
        }
        return false;
    }

    pub fn skipTrivia(self: *Cursor) void {
        while (self.current) |current| {
            if (current.asToken()) |tok| {
                if (tok.isTrivia()) {
                    self.advance();
                    continue;
                }
            }
            break;
        }
    }

    fn advanceToNext(self: *Cursor, current: SyntaxElement) void {
        switch (current) {
            .node => |node| {
                if (node.firstChild()) |child| {
                    self.current = child;
                    self.position += 1;
                    return;
                }
                self.findNextAfter(node.spanEnd());
            },
            .token => |tok| {
                self.findNextAfter(tok.spanEnd());
            },
        }
    }

    fn findNextAfter(self: *Cursor, after: u32) void {
        _ = after;
        self.current = null;
    }

    fn findParent(self: *const Cursor, current: SyntaxElement) ?SyntaxElement {
        _ = self;
        _ = current;
        return null;
    }
};
