const std = @import("std");
const ast = @import("../../parser/ast.zig");
const Allocator = std.mem.Allocator;

pub const SlotKind = enum {
    hstdin,
    hstdout,
    chars_read,
    chars_written,
    cur_state,
    cursor,
    remaining,
    abudget,
    core_type,
    numa_highest_node,
    numa_node_mask,
    pool_head,
    l1_base,
    l1_ptr,
    l1_end,
    l1_buf,
    l2_base,
    l2_ptr,
    l2_end,
    l2_buf,
    l3_base,
    l3_ptr,
    l3_end,
    l3_buf,
    telem_l1_spill,
    telem_l2_spill,
    telem_l1_peak,
    telem_l2_peak,
    telem_l3_peak,
    telem_l1_allocs,
    telem_l2_allocs,
    telem_l3_allocs,
    state_hits,
    trans_hits,
    buf,
    epoch,
    for_loop_x,
    for_loop_y,
    ht_tiers,
    ht_states,
    ht_heats,
    ht_total_heats,
    ht_generations,
    ht_sizes,
    ht_free_next,
    ht_free_head,
    ht_ptrs,
    arg0,
    arg1,
    arg2,
    arg3,
    pad,
    user_var,
};

pub const Slot = struct {
    kind: SlotKind,
    offset: i32,
    size: u32,
    note: []const u8 = "",
};

pub const HT_SLOTS: u32 = 64;
pub const HEAT_SLOTS: u32 = 32;
pub const BUF_SIZE: u32 = 256;
pub const HT_PTRS_SIZE: u32 = 512;
pub const HT_HEATS_SIZE: u32 = 256;
pub const HT_GENERATIONS_SIZE: u32 = 256;
pub const HT_SIZES_SIZE: u32 = 256;
pub const HT_FREE_NEXT_SIZE: u32 = 256;

pub const StackFrame = struct {
    slots: std.ArrayList(Slot),
    frame_size: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) StackFrame {
        return .{
            .slots = std.ArrayList(Slot).init(allocator),
            .frame_size = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StackFrame) void {
        self.slots.deinit();
    }

    pub fn addSlot(self: *StackFrame, kind: SlotKind, size: u32) !void {
        try self.addSlotNote(kind, size, "");
    }

    pub fn addSlotNote(self: *StackFrame, kind: SlotKind, size: u32, note: []const u8) !void {
        const off = if (self.slots.items.len == 0)
            @as(i32, -@as(i32, @intCast(size)))
        else
            self.slots.items[self.slots.items.len - 1].offset - @as(i32, @intCast(self.slots.items[self.slots.items.len - 1].size));
        try self.slots.append(.{ .kind = kind, .offset = off, .size = size, .note = note });
    }

    pub fn addSlotAt(self: *StackFrame, kind: SlotKind, offset: i32, size: u32) !void {
        try self.slots.append(.{ .kind = kind, .offset = offset, .size = size, .note = "" });
    }

    pub fn currentOff(self: *const StackFrame) i32 {
        if (self.slots.items.len == 0) return 0;
        const last = self.slots.items[self.slots.items.len - 1];
        return last.offset - @as(i32, @intCast(last.size));
    }

    pub fn getOffset(self: *const StackFrame, kind: SlotKind) ?i32 {
        var i = self.slots.items.len;
        while (i > 0) {
            i -= 1;
            if (self.slots.items[i].kind == kind) return self.slots.items[i].offset;
        }
        return null;
    }

    pub fn getNote(self: *const StackFrame, kind: SlotKind) ?[]const u8 {
        var i = self.slots.items.len;
        while (i > 0) {
            i -= 1;
            if (self.slots.items[i].kind == kind) return self.slots.items[i].note;
        }
        return null;
    }
};

pub const StateVarInfo = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: []const u8,
    stack_offset: i32,
    size: u32,
    cache_policy: ?[]const u8,
    layout_offset: u32,
};

pub const ContextVarInfo = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: []const u8,
};
