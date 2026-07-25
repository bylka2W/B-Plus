const std = @import("std");
const green_node_mod = @import("../green/green_node.zig");
const green_token_mod = @import("../green/green_token.zig");
const green_tree_mod = @import("../green/green_tree.zig");

pub const SyntaxKind = green_node_mod.SyntaxKind;
pub const GreenNode = green_node_mod.GreenNode;
pub const GreenToken = green_token_mod.GreenToken;
pub const GreenTree = green_tree_mod.GreenTree;
pub const ChildSlot = GreenNode.ChildSlot;

pub const Event = union(enum) {
    start_node: StartNode,
    finish_node: FinishNode,
    add_token: AddToken,
    add_trivia: AddTrivia,
    add_node: AddNode,
    error_event: ErrorEvent,

    pub const StartNode = struct {
        kind: SyntaxKind,
    };

    pub const FinishNode = struct {};

    pub const AddToken = struct {
        kind: SyntaxKind,
        text: []const u8,
        span_start: u32,
        span_end: u32,
    };

    pub const AddTrivia = struct {
        kind: SyntaxKind,
        text: []const u8,
        span_start: u32,
        span_end: u32,
    };

    pub const AddNode = struct {
        node: *GreenNode,
    };

    pub const ErrorEvent = struct {
        message: []const u8,
        span_start: u32,
        span_end: u32,
    };
};

pub const EventSink = struct {
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) EventSink {
        return .{
            .events = std.ArrayList(Event).init(allocator),
        };
    }

    pub fn deinit(self: *EventSink) void {
        self.events.deinit();
    }

    pub fn startNode(self: *EventSink, kind: SyntaxKind) u32 {
        const idx: u32 = @intCast(self.events.items.len);
        self.events.append(.{ .start_node = .{ .kind = kind } }) catch return 0;
        return idx;
    }

    pub fn insertStartNode(self: *EventSink, kind: SyntaxKind, at: u32) void {
        self.events.insert(at, .{ .start_node = .{ .kind = kind } }) catch return;
    }

    pub fn finishNode(self: *EventSink) void {
        self.events.append(.{ .finish_node = .{} }) catch return;
    }

    pub fn addToken(self: *EventSink, kind: SyntaxKind, text: []const u8, start: u32, end: u32) void {
        self.events.append(.{ .add_token = .{
            .kind = kind,
            .text = text,
            .span_start = start,
            .span_end = end,
        } }) catch return;
    }

    pub fn addTrivia(self: *EventSink, kind: SyntaxKind, text: []const u8, start: u32, end: u32) void {
        self.events.append(.{ .add_trivia = .{
            .kind = kind,
            .text = text,
            .span_start = start,
            .span_end = end,
        } }) catch return;
    }

    pub fn addNode(self: *EventSink, node: *GreenNode) void {
        self.events.append(.{ .add_node = .{ .node = node } }) catch return;
    }

    pub fn addError(self: *EventSink, message: []const u8, start: u32, end: u32) void {
        self.events.append(.{ .error_event = .{
            .message = message,
            .span_start = start,
            .span_end = end,
        } }) catch return;
    }

    pub fn build(self: *EventSink, tree: *GreenTree, kind: SyntaxKind) !*GreenNode {
        return buildFromEvents(tree, self.events.items, kind);
    }

    pub fn slice(self: *const EventSink) []const Event {
        return self.events.items;
    }
};

pub fn buildFromEvents(tree: *GreenTree, events: []const Event, root_kind: SyntaxKind) !*GreenNode {
    var node_stack = std.ArrayList(struct {
        kind: SyntaxKind,
        children: std.ArrayList(ChildSlot),
    }).init(tree.node_arena.allocator());
    defer {
        for (node_stack.items) |*item| {
            item.children.deinit();
        }
        node_stack.deinit();
    }

    try node_stack.append(.{
        .kind = root_kind,
        .children = std.ArrayList(ChildSlot).init(tree.node_arena.allocator()),
    });

    for (events) |event| {
        switch (event) {
            .start_node => |start| {
                try node_stack.append(.{
                    .kind = start.kind,
                    .children = std.ArrayList(ChildSlot).init(tree.node_arena.allocator()),
                });
            },
            .finish_node => {
                if (node_stack.items.len <= 1) continue;
                const finished = node_stack.pop() orelse unreachable;
                defer finished.children.deinit();

                const node = try tree.allocNode(finished.kind, finished.children.items);
                if (node_stack.items.len > 0) {
                    try node_stack.items[node_stack.items.len - 1].children.append(.{ .node = node });
                }
            },
            .add_token => |tok| {
                if (node_stack.items.len == 0) continue;
                const text_copy = try tree.node_arena.allocator().dupe(u8, tok.text);
                const green_tok = GreenToken.init(tok.kind, text_copy, tok.span_start, tok.span_end);
                try node_stack.items[node_stack.items.len - 1].children.append(.{ .token = green_tok });
            },
            .add_trivia => |triv| {
                if (node_stack.items.len == 0) continue;
                const text_copy = try tree.node_arena.allocator().dupe(u8, triv.text);
                const green_tok = GreenToken.init(triv.kind, text_copy, triv.span_start, triv.span_end);
                try node_stack.items[node_stack.items.len - 1].children.append(.{ .trivia = green_tok });
            },
            .add_node => |n| {
                if (node_stack.items.len == 0) continue;
                try node_stack.items[node_stack.items.len - 1].children.append(.{ .node = n.node });
            },
            .error_event => {
                // errors tracked separately
            },
        }
    }

    if (node_stack.items.len == 0) {
        return tree.allocNode(root_kind, &.{});
    }

    const root = node_stack.items[0];
    const result = try tree.allocNode(root.kind, root.children.items);
    return result;
}
