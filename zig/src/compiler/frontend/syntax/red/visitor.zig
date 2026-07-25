const std = @import("std");
const syntax_node_mod = @import("syntax_node.zig");

pub const SyntaxNode = syntax_node_mod.SyntaxNode;
pub const SyntaxToken = syntax_node_mod.SyntaxToken;
pub const SyntaxElement = syntax_node_mod.SyntaxElement;
pub const SyntaxKind = syntax_node_mod.SyntaxKind;

pub fn Visitor(comptime Context: type) type {
    return struct {
        context: Context,
        visit_node_fn: ?*const fn (*Self, Context, SyntaxNode) ?Context,
        visit_token_fn: ?*const fn (*Self, Context, SyntaxToken) void,

        const Self = @This();

        pub const VTable = struct {
            visit_node: ?*const fn (*Self, Context, SyntaxNode) ?Context,
            visit_token: ?*const fn (*Self, Context, SyntaxToken) void,
        };

        pub fn init(ctx: Context, vtable: VTable) Self {
            return .{
                .context = ctx,
                .visit_node_fn = vtable.visit_node,
                .visit_token_fn = vtable.visit_token,
            };
        }

        pub fn walk(self: *Self, node: SyntaxNode) void {
            self.visitNode(node);
        }

        pub fn visitNode(self: *Self, node: SyntaxNode) void {
            if (self.visit_node_fn) |fn_ptr| {
                const new_ctx = fn_ptr(self, self.context, node) orelse return;
                self.context = new_ctx;
            }

            var iter = node.childNodes();
            while (iter.next()) |child| {
                self.visitNode(child);
            }

            var tok_iter = node.childTokens();
            while (tok_iter.next()) |tok| {
                self.visitToken(tok);
            }
        }

        pub fn visitToken(self: *Self, tok: SyntaxToken) void {
            if (self.visit_token_fn) |fn_ptr| {
                fn_ptr(self, self.context, tok);
            }
        }
    };
}

pub fn NodeFinder(comptime kind: SyntaxKind) type {
    return struct {
        results: std.ArrayList(SyntaxNode),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .results = std.ArrayList(SyntaxNode).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.results.deinit();
        }

        pub fn find(self: *@This(), root: SyntaxNode) void {
            self.walk(root);
        }

        fn walk(self: *@This(), node: SyntaxNode) void {
            if (node.kind() == kind) {
                self.results.append(node) catch return;
            }
            var iter = node.childNodes();
            while (iter.next()) |child| {
                self.walk(child);
            }
        }

        pub fn first(self: *const @This()) ?SyntaxNode {
            if (self.results.items.len > 0) return self.results.items[0];
            return null;
        }

        pub fn count(self: *const @This()) u32 {
            return @intCast(self.results.items.len);
        }
    };
}

pub fn TokenFinder(comptime token_kind: syntax_node_mod.TokenKind) type {
    return struct {
        results: std.ArrayList(SyntaxToken),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .results = std.ArrayList(SyntaxToken).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.results.deinit();
        }

        pub fn find(self: *@This(), root: SyntaxNode) void {
            self.walk(root);
        }

        fn walk(self: *@This(), node: SyntaxNode) void {
            var iter = node.childTokens();
            while (iter.next()) |tok| {
                if (tok.kind() == token_kind) {
                    self.results.append(tok) catch return;
                }
            }
            var node_iter = node.childNodes();
            while (node_iter.next()) |child| {
                self.walk(child);
            }
        }

        pub fn first(self: *const @This()) ?SyntaxToken {
            if (self.results.items.len > 0) return self.results.items[0];
            return null;
        }

        pub fn count(self: *const @This()) u32 {
            return @intCast(self.results.items.len);
        }
    };
}
