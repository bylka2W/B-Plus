const std = @import("std");
const bir = @import("../middle/bir/bir.zig");
const bir_cfg = @import("../middle/bir/bir_cfg.zig");

const Allocator = std.mem.Allocator;
const ValueId = bir.ValueId;

pub const InitDiagnostic = struct {
    func_name: []const u8,
    block_name: []const u8,
    inst_idx: u32,
    slot_name: []const u8,
    message: []const u8,
};

pub const InitChecker = struct {
    allocator: Allocator,
    diagnostics: std.ArrayList(InitDiagnostic),

    pub fn init(allocator: Allocator) InitChecker {
        return .{
            .allocator = allocator,
            .diagnostics = std.ArrayList(InitDiagnostic).init(allocator),
        };
    }

    pub fn deinit(self: *InitChecker) void {
        for (self.diagnostics.items) |d| {
            self.allocator.free(d.func_name);
            self.allocator.free(d.block_name);
            self.allocator.free(d.slot_name);
            self.allocator.free(d.message);
        }
        self.diagnostics.deinit();
    }

    pub fn checkModule(self: *InitChecker, module: *bir.Module) !void {
        for (module.functions.items, 0..) |*func, fid| {
            try self.checkFunction(func, @intCast(fid));
        }
    }

    fn checkFunction(self: *InitChecker, func: *bir.Function, fid: bir.FunctionId) !void {
        _ = fid;
        if (func.blocks.items.len == 0) return;

        var cfg = try bir_cfg.buildCFG(self.allocator, func);
        defer cfg.deinit();

        const num_slots = self.countAllocas(func);
        if (num_slots == 0) return;

        const slot_ids = try self.collectAllocaSlots(func);
        defer self.allocator.free(slot_ids);

        var slot_names = try std.ArrayList([]const u8).initCapacity(self.allocator, slot_ids.len);
        defer slot_names.deinit();
        for (slot_ids) |sid| {
            const name = func.value_debug_names.get(sid) orelse "?";
            slot_names.appendAssumeCapacity(name);
        }

        var block_states = try std.ArrayList(BlockState).initCapacity(self.allocator, func.blocks.items.len);
        defer {
            for (block_states.items) |*bs| bs.deinit(self.allocator);
            block_states.deinit();
        }
        for (func.blocks.items) |_| {
            var bs = try BlockState.init(self.allocator, slot_ids.len);
            errdefer bs.deinit(self.allocator);
            for (slot_ids, 0..) |_, i| {
                bs.initialized[i] = false;
            }
            block_states.appendAssumeCapacity(bs);
        }

        var changed = true;
        var iter_count: u32 = 0;
        while (changed and iter_count < 100) {
            iter_count += 1;
            changed = false;
            for (cfg.rpo.items) |bid| {
                var entry_state = try BlockState.init(self.allocator, slot_ids.len);
                defer entry_state.deinit(self.allocator);
                for (slot_ids, 0..) |_, i| {
                    entry_state.initialized[i] = true;
                }

                const blk = &func.blocks.items[bid];
                if (bid == 0) {
                    for (slot_ids, 0..) |_, i| {
                        entry_state.initialized[i] = false;
                    }
                } else if (blk.preds.items.len > 0) {
                    for (slot_ids, 0..) |_, i| {
                        entry_state.initialized[i] = true;
                    }
                    for (blk.preds.items) |pred_id| {
                        const pred_state = &block_states.items[pred_id];
                        for (slot_ids, 0..) |_, i| {
                            entry_state.initialized[i] = entry_state.initialized[i] and pred_state.initialized[i];
                        }
                    }
                } else {
                    for (slot_ids, 0..) |_, i| {
                        entry_state.initialized[i] = false;
                    }
                }

                var exit_state = try BlockState.init(self.allocator, slot_ids.len);
                defer exit_state.deinit(self.allocator);
                for (slot_ids, 0..) |_, i| {
                    exit_state.initialized[i] = entry_state.initialized[i];
                }

                for (blk.instrs.items) |inst| {
                    switch (inst.op) {
                        .store => {
                            if (inst.operands.len >= 2) {
                                const ptr_val = inst.operands[0];
                                for (slot_ids, 0..) |sid, i| {
                                    if (ptr_val == sid) {
                                        exit_state.initialized[i] = true;
                                        break;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }

                const cur_state = &block_states.items[bid];
                var eq = true;
                for (slot_ids, 0..) |_, i| {
                    if (cur_state.initialized[i] != exit_state.initialized[i]) {
                        eq = false;
                        break;
                    }
                }
                if (!eq) {
                    for (slot_ids, 0..) |_, i| {
                        cur_state.initialized[i] = exit_state.initialized[i];
                    }
                    changed = true;
                }
            }
        }

        for (func.blocks.items, 0..) |*blk, bid| {
            const cur_state = block_states.items[bid];
            var entry_state = try BlockState.init(self.allocator, slot_ids.len);
            defer entry_state.deinit(self.allocator);
            for (slot_ids, 0..) |_, i| {
                entry_state.initialized[i] = cur_state.initialized[i];
            }

            for (blk.instrs.items, 0..) |inst, idx| {
                if (inst.op == .load) {
                    if (inst.operands.len >= 1) {
                        const ptr_val = inst.operands[0];
                        for (slot_ids, 0..) |sid, i| {
                            if (ptr_val == sid) {
                                if (!entry_state.initialized[i]) {
                                    const msg = try std.fmt.allocPrint(self.allocator,
                                        "variable '{s}' is used before initialization",
                                        .{slot_names.items[i]},
                                    );
                                    try self.diagnostics.append(.{
                                        .func_name = try self.allocator.dupe(u8, func.name),
                                        .block_name = try self.allocator.dupe(u8, blk.label),
                                        .inst_idx = @intCast(idx),
                                        .slot_name = try self.allocator.dupe(u8, slot_names.items[i]),
                                        .message = msg,
                                    });
                                }
                                break;
                            }
                        }
                    }
                }
                if (inst.op == .store) {
                    if (inst.operands.len >= 2) {
                        const ptr_val = inst.operands[0];
                        for (slot_ids, 0..) |sid, i| {
                            if (ptr_val == sid) {
                                entry_state.initialized[i] = true;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    fn countAllocas(self: *InitChecker, func: *const bir.Function) usize {
        _ = self;
        var count: usize = 0;
        for (func.blocks.items) |*blk| {
            for (blk.instrs.items) |inst| {
                if (inst.op == .alloca) count += 1;
            }
        }
        return count;
    }

    fn collectAllocaSlots(self: *InitChecker, func: *const bir.Function) ![]ValueId {
        const count = self.countAllocas(func);
        var slots = try self.allocator.alloc(ValueId, count);
        var idx: usize = 0;
        for (func.blocks.items) |*blk| {
            for (blk.instrs.items) |inst| {
                if (inst.op == .alloca) {
                    slots[idx] = inst.result;
                    idx += 1;
                }
            }
        }
        return slots;
    }
};

const BlockState = struct {
    initialized: []bool,

    fn init(allocator: Allocator, num_slots: usize) !BlockState {
        const inits = try allocator.alloc(bool, num_slots);
        return .{ .initialized = inits };
    }

    fn deinit(self: *BlockState, allocator: Allocator) void {
        allocator.free(self.initialized);
    }
};
