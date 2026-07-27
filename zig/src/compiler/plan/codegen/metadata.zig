const std = @import("std");
const plan_ir = @import("../ir/plan.zig");

pub const PlanMagic: u32 = 0x504C414E;
pub const PlanVersion: u32 = 1;

fn align16(x: usize) usize {
    return (x + 15) & ~@as(usize, 15);
}

fn writePadding(writer: anytype, actual: usize, aligned: usize) !void {
    const pad = aligned - actual;
    var i: usize = 0;
    while (i < pad) : (i += 1) {
        try writer.writeByte(0);
    }
}

pub const BinHeader = extern struct {
    magic: u32,
    version: u32,
    state_count: u32,
    event_count: u32,
    transition_count: u32,
    dispatch_columns: u32,
    initial_state: u32,
};

pub const BinState = extern struct {
    id: u32,
    entry_fn_offset: i32,
    exit_fn_offset: i32,
    update_fn_offset: i32,
    flags: u32,
    variable_count: u32,
};

pub const BinTransition = extern struct {
    id: u32,
    from: u32,
    event: u32,
    to: u32,
    guard_fn_offset: i32,
    action_fn_offset: i32,
    priority: u32,
    flags: u32,
};

pub const BinEvent = extern struct {
    id: u32,
    payload_type: u32,
};

pub const BinDispatchEntry = extern struct {
    start: u32,
    end: u32,
};

pub const MetadataSerializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MetadataSerializer {
        return .{ .allocator = allocator };
    }

    pub fn serialize(self: MetadataSerializer, metadata: plan_ir.PlanMetadata) ![]u8 {
        const graph = metadata.graph;

        const header_size = align16(@sizeOf(BinHeader));
        const states_size = align16(@sizeOf(BinState) * graph.state_count);
        const transitions_size = align16(@sizeOf(BinTransition) * graph.transition_count);
        const events_size = align16(@sizeOf(BinEvent) * graph.event_count);
        const dispatch_size = align16(@sizeOf(BinDispatchEntry) * graph.dispatch_table.len);

        const total_size = header_size + states_size + transitions_size + events_size + dispatch_size;
        var buf = try self.allocator.alloc(u8, total_size);
        for (buf) |*b| b.* = 0;
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        const header = BinHeader{
            .magic = PlanMagic,
            .version = PlanVersion,
            .state_count = graph.state_count,
            .event_count = graph.event_count,
            .transition_count = graph.transition_count,
            .dispatch_columns = graph.dispatchColumns(),
            .initial_state = graph.initial_state.index,
        };
        try writer.writeAll(std.mem.asBytes(&header));
        try writePadding(writer, @sizeOf(BinHeader), header_size);

        for (graph.states) |s| {
            const bs = BinState{
                .id = s.id.index,
                .entry_fn_offset = if (s.entry_fn) |f| @intCast(f.index) else -1,
                .exit_fn_offset = if (s.exit_fn) |f| @intCast(f.index) else -1,
                .update_fn_offset = if (s.update_fn) |f| @intCast(f.index) else -1,
                .flags = @bitCast(s.flags),
                .variable_count = s.variable_count,
            };
            try writer.writeAll(std.mem.asBytes(&bs));
        }
        try writePadding(writer, @sizeOf(BinState) * graph.state_count, states_size);

        for (graph.transitions) |t| {
            const bt = BinTransition{
                .id = t.id.index,
                .from = t.from.index,
                .event = if (t.event) |e| e.index else plan_ir.ALWAYS_EVENT_INDEX,
                .to = t.to.index,
                .guard_fn_offset = if (t.guard_fn) |f| @intCast(f.index) else -1,
                .action_fn_offset = if (t.action_fn) |f| @intCast(f.index) else -1,
                .priority = t.priority,
                .flags = @bitCast(t.flags),
            };
            try writer.writeAll(std.mem.asBytes(&bt));
        }
        try writePadding(writer, @sizeOf(BinTransition) * graph.transition_count, transitions_size);

        for (graph.events) |e| {
            const be = BinEvent{
                .id = e.id.index,
                .payload_type = @intFromEnum(e.payload),
            };
            try writer.writeAll(std.mem.asBytes(&be));
        }
        try writePadding(writer, @sizeOf(BinEvent) * graph.event_count, events_size);

        for (graph.dispatch_table) |d| {
            const bd = BinDispatchEntry{
                .start = d.start,
                .end = d.end,
            };
            try writer.writeAll(std.mem.asBytes(&bd));
        }

        return buf;
    }

    pub fn deserialize(self: MetadataSerializer, data: []const u8) !plan_ir.PlanGraph {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        const header = try reader.readStruct(BinHeader);
        if (header.magic != PlanMagic) return error.invalid_magic;
        if (header.version != PlanVersion) return error.invalid_version;

        var states = try self.allocator.alloc(plan_ir.State, header.state_count);
        for (states) |*s| {
            const bs = try reader.readStruct(BinState);
            s.* = .{
                .id = plan_ir.PlanStateId.new(bs.id),
                .name = @import("../../frontend/foundation/ids/ids.zig").SymbolId.INVALID,
                .def_id = @import("../../frontend/foundation/ids/ids.zig").DefId.INVALID,
                .entry_fn = if (bs.entry_fn_offset >= 0) @import("../../frontend/foundation/ids/ids.zig").BodyId.new(@intCast(bs.entry_fn_offset)) else null,
                .exit_fn = if (bs.exit_fn_offset >= 0) @import("../../frontend/foundation/ids/ids.zig").BodyId.new(@intCast(bs.exit_fn_offset)) else null,
                .update_fn = if (bs.update_fn_offset >= 0) @import("../../frontend/foundation/ids/ids.zig").BodyId.new(@intCast(bs.update_fn_offset)) else null,
                .flags = @bitCast(bs.flags),
                .variable_count = bs.variable_count,
            };
        }

        var transitions = try self.allocator.alloc(plan_ir.Transition, header.transition_count);
        for (transitions) |*t| {
            const bt = try reader.readStruct(BinTransition);
            t.* = .{
                .id = plan_ir.PlanTransitionId.new(bt.id),
                .from = plan_ir.PlanStateId.new(bt.from),
                .event = if (bt.event != plan_ir.ALWAYS_EVENT_INDEX) plan_ir.PlanEventId.new(bt.event) else null,
                .to = plan_ir.PlanStateId.new(bt.to),
                .guard_fn = if (bt.guard_fn_offset >= 0) @import("../../frontend/foundation/ids/ids.zig").BodyId.new(@intCast(bt.guard_fn_offset)) else null,
                .action_fn = if (bt.action_fn_offset >= 0) @import("../../frontend/foundation/ids/ids.zig").BodyId.new(@intCast(bt.action_fn_offset)) else null,
                .priority = bt.priority,
                .flags = @bitCast(bt.flags),
            };
        }

        var events = try self.allocator.alloc(plan_ir.EventDef, header.event_count);
        for (events) |*e| {
            const be = try reader.readStruct(BinEvent);
            e.* = .{
                .id = plan_ir.PlanEventId.new(be.id),
                .name = @import("../../frontend/foundation/ids/ids.zig").SymbolId.INVALID,
                .payload = @enumFromInt(be.payload_type),
            };
        }

        const dispatch_len: usize = @as(usize, header.state_count) * @as(usize, header.dispatch_columns);
        var dispatch_table = try self.allocator.alloc(plan_ir.TransitionRange, dispatch_len);
        for (dispatch_table) |*d| {
            const bd = try reader.readStruct(BinDispatchEntry);
            d.* = .{ .start = bd.start, .end = bd.end };
        }

        return plan_ir.PlanGraph{
            .states = states,
            .transitions = transitions,
            .events = events,
            .dispatch_table = dispatch_table,
            .initial_state = plan_ir.PlanStateId.new(header.initial_state),
            .state_count = header.state_count,
            .transition_count = header.transition_count,
            .event_count = header.event_count,
        };
    }
};
