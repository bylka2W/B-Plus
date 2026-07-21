const std = @import("std");
const value = @import("value.zig");
const instruction = @import("instruction.zig");
const ValueId = value.ValueId;
const BlockId = value.BlockId;
const Inst = instruction.Inst;

pub const LoopInfo = struct {
    header: BlockId,
    preheader: BlockId,
    latch: BlockId,
    exits: []BlockId,
    depth: u32,
    induction_vars: []ValueId,
};

pub const BasicBlock = struct {
    label: []const u8,
    instrs: std.ArrayList(Inst),
    next_value_id: ValueId,
    preds: std.ArrayList(BlockId),
    succs: std.ArrayList(BlockId),
    phi_count: u32,

    pub fn deinit(self: *BasicBlock, allocator: std.mem.Allocator) void {
        for (self.instrs.items) |*inst| inst.deinit(allocator);
        self.instrs.deinit();
        self.preds.deinit();
        self.succs.deinit();
        if (self.label.len > 0) allocator.free(self.label);
    }
};
