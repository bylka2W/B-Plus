const std = @import("std");
const bir = @import("../middle/bir/bir.zig");
const bir_cfg = @import("../middle/bir/bir_cfg.zig");

const Allocator = std.mem.Allocator;
const ValueId = bir.ValueId;

/// Above this many bytes a slot is tracked as one opaque byte instead of
/// byte-by-byte, so a huge `alloca` cannot blow up the analysis state.
const max_tracked_bytes = 4096;

pub const InitDiagnostic = struct {
    func_name: []const u8,
    block_name: []const u8,
    inst_idx: u32,
    slot_name: []const u8,
    message: []const u8,
};

/// A half-open byte range inside a tracked slot.
const Range = struct {
    start: u32,
    end: u32,
};

/// One `alloca` whose initialization the checker tracks.
const Slot = struct {
    /// The value produced by the `alloca`.
    value: ValueId,
    /// Debug name used in the diagnostic ("user", not "val#3").
    name: []const u8,
    /// Bytes covered by this slot's slice of the per-block state.
    size: u32,
    /// Ranges that have to be written before the slot counts as initialized.
    /// For a struct these are the declared fields, so padding between fields is
    /// never demanded; for a scalar it is the single range covering the value.
    required: []Range,
    /// Non-struct slot: any store initializes it, which is the historical rule
    /// and the only one that cannot produce false positives for scalars.
    scalar: bool,
    /// Slot too large to track byte-by-byte; behaves like `scalar`.
    big: bool,
};

/// Where a pointer value points inside a tracked slot.
const Derived = struct {
    slot: u32,
    offset: u32,
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
            try self.checkFunction(module, func, @intCast(fid));
        }
    }

    /// Collects every `alloca` of the function together with what has to be
    /// written for it to count as initialized.
    fn collectSlots(self: *InitChecker, module: *bir.Module, func: *bir.Function) !std.ArrayList(Slot) {
        var slots = std.ArrayList(Slot).init(self.allocator);
        errdefer {
            for (slots.items) |s| self.allocator.free(s.required);
            slots.deinit();
        }

        for (func.blocks.items) |*blk| {
            for (blk.instrs.items) |inst| {
                if (inst.op != .alloca) continue;

                const raw = module.types.sizeOf(inst.ty);
                const name = func.value_debug_names.get(inst.result) orelse "?";
                const is_struct = switch (module.types.get(inst.ty).kind) {
                    .struct_type => true,
                    else => false,
                };

                if (raw == 0 or raw > max_tracked_bytes) {
                    const one = try self.allocator.alloc(Range, 1);
                    one[0] = .{ .start = 0, .end = 1 };
                    try slots.append(.{
                        .value = inst.result,
                        .name = name,
                        .size = 1,
                        .required = one,
                        .scalar = true,
                        .big = true,
                    });
                    continue;
                }

                const required = if (is_struct)
                    try self.structFieldRanges(module, inst.ty, raw)
                else
                    try self.wholeRange(raw);

                try slots.append(.{
                    .value = inst.result,
                    .name = name,
                    .size = raw,
                    .required = required,
                    .scalar = !is_struct,
                    .big = false,
                });
            }
        }
        return slots;
    }

    fn wholeRange(self: *InitChecker, size: u32) ![]Range {
        const one = try self.allocator.alloc(Range, 1);
        one[0] = .{ .start = 0, .end = size };
        return one;
    }

    /// Byte range of every declared field, so that reading a whole struct only
    /// demands the fields and not the padding between them.
    fn structFieldRanges(self: *InitChecker, module: *bir.Module, ty: bir.TypeId, size: u32) ![]Range {
        var ranges = std.ArrayList(Range).init(self.allocator);
        errdefer ranges.deinit();

        switch (module.types.get(ty).kind) {
            .struct_type => |st| {
                for (st.offsets, st.fields) |off, fty| {
                    const field_size = module.types.sizeOf(fty);
                    if (field_size == 0) continue;
                    const start = @min(off, size);
                    const end = @min(off + field_size, size);
                    if (end > start) try ranges.append(.{ .start = start, .end = end });
                }
            },
            else => {},
        }

        if (ranges.items.len == 0) try ranges.append(.{ .start = 0, .end = size });
        return try ranges.toOwnedSlice();
    }

    /// Maps every pointer value that is derived from a tracked slot to the slot
    /// and the byte offset inside it. Field addresses are built as
    /// `add(slot, constant_offset)`, so without this a store to `user.score`
    /// looked like a store to an unknown pointer and the slot stayed
    /// "uninitialized" forever.
    fn buildProvenance(self: *InitChecker, func: *bir.Function, slots: []const Slot) !std.AutoHashMap(ValueId, Derived) {
        var prov = std.AutoHashMap(ValueId, Derived).init(self.allocator);
        errdefer prov.deinit();

        var consts = std.AutoHashMap(ValueId, i64).init(self.allocator);
        defer consts.deinit();

        for (func.blocks.items) |*blk| {
            for (blk.instrs.items) |inst| {
                if (inst.op != .@"const") continue;
                switch (inst.data) {
                    .const_data => |cd| switch (cd) {
                        .int => |v| try consts.put(inst.result, v),
                        else => {},
                    },
                    else => {},
                }
            }
        }

        for (slots, 0..) |s, i| try prov.put(s.value, .{ .slot = @intCast(i), .offset = 0 });

        for (func.blocks.items) |*blk| {
            for (blk.instrs.items) |inst| {
                switch (inst.op) {
                    .add, .ptr_offset => {
                        if (inst.operands.len < 2) continue;
                        const base = prov.get(inst.operands[0]) orelse continue;
                        const delta = consts.get(inst.operands[1]) orelse continue;
                        if (delta < 0) continue;
                        const sum = base.offset + @as(u32, @intCast(delta));
                        try prov.put(inst.result, .{ .slot = base.slot, .offset = if (sum < base.offset) base.offset else sum });
                    },
                    else => {},
                }
            }
        }
        return prov;
    }

    fn markWritten(state: []bool, base: usize, slot: Slot, offset: u32, written: u32) void {
        if (slot.scalar or slot.big) {
            state[base] = true;
            return;
        }
        // A store that covers the whole slot initializes all of it.
        if (offset == 0 and written >= slot.size) {
            @memset(state[base..][0..slot.size], true);
            return;
        }
        const start = @min(offset, slot.size);
        const end = @min(offset + written, slot.size);
        var i = start;
        while (i < end) : (i += 1) state[base + i] = true;
    }

    fn isInitialized(state: []bool, base: usize, slot: Slot, offset: u32, read: u32) bool {
        if (slot.scalar or slot.big) return state[base];

        // Reading the whole slot only requires the declared fields, because the
        // padding between them is never written by anyone.
        if (offset == 0 and read >= slot.size) {
            for (slot.required) |r| {
                var i = r.start;
                while (i < r.end) : (i += 1) {
                    if (!state[base + i]) return false;
                }
            }
            return true;
        }

        const start = @min(offset, slot.size);
        const end = @min(offset + read, slot.size);
        var i = start;
        while (i < end) : (i += 1) {
            if (!state[base + i]) return false;
        }
        return true;
    }

    fn checkFunction(self: *InitChecker, module: *bir.Module, func: *bir.Function, fid: bir.FunctionId) !void {
        _ = fid;
        if (func.blocks.items.len == 0) return;

        var slots = try self.collectSlots(module, func);
        defer {
            for (slots.items) |s| self.allocator.free(s.required);
            slots.deinit();
        }
        if (slots.items.len == 0) return;

        const slot_base = try self.allocator.alloc(usize, slots.items.len);
        defer self.allocator.free(slot_base);
        var total_bytes: usize = 0;
        for (slots.items, 0..) |s, i| {
            slot_base[i] = total_bytes;
            total_bytes += s.size;
        }
        if (total_bytes == 0) return;

        var prov = try self.buildProvenance(func, slots.items);
        defer prov.deinit();

        var cfg = try bir_cfg.buildCFG(self.allocator, func);
        defer cfg.deinit();

        const states = try self.allocator.alloc([]bool, func.blocks.items.len);
        defer {
            for (states) |st| self.allocator.free(st);
            self.allocator.free(states);
        }
        for (states) |*st| {
            st.* = try self.allocator.alloc(bool, total_bytes);
            @memset(st.*, false);
        }

        // Forward dataflow to a fixpoint. A byte survives the join only when
        // every predecessor wrote it, so a field assigned inside one branch of
        // an `if` is still uninitialized afterwards.
        var changed = true;
        var iter_count: u32 = 0;
        while (changed and iter_count < 100) {
            iter_count += 1;
            changed = false;
            for (cfg.rpo.items) |bid| {
                const entry_state = try self.allocator.alloc(bool, total_bytes);
                defer self.allocator.free(entry_state);

                const blk = &func.blocks.items[bid];
                if (bid != 0 and blk.preds.items.len > 0) {
                    @memset(entry_state, true);
                    for (blk.preds.items) |pred_id| {
                        const pred_state = states[pred_id];
                        for (entry_state, 0..) |*e, bi| e.* = e.* and pred_state[bi];
                    }
                } else {
                    @memset(entry_state, false);
                }

                const exit_state = try self.allocator.alloc(bool, total_bytes);
                defer self.allocator.free(exit_state);
                @memcpy(exit_state, entry_state);

                for (blk.instrs.items) |inst| {
                    if (inst.op != .store or inst.operands.len < 2) continue;
                    const d = prov.get(inst.operands[0]) orelse continue;
                    markWritten(
                        exit_state,
                        slot_base[d.slot],
                        slots.items[d.slot],
                        d.offset,
                        module.types.sizeOf(inst.ty),
                    );
                }

                if (!std.mem.eql(bool, states[bid], exit_state)) {
                    @memcpy(states[bid], exit_state);
                    changed = true;
                }
            }
        }

        for (func.blocks.items, 0..) |*blk, bid| {
            const cur_state = try self.allocator.alloc(bool, total_bytes);
            defer self.allocator.free(cur_state);
            @memcpy(cur_state, states[bid]);

            for (blk.instrs.items, 0..) |inst, idx| {
                switch (inst.op) {
                    .load => {
                        if (inst.operands.len < 1) continue;
                        const d = prov.get(inst.operands[0]) orelse continue;
                        const slot = slots.items[d.slot];
                        if (isInitialized(cur_state, slot_base[d.slot], slot, d.offset, module.types.sizeOf(inst.ty))) continue;
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "variable '{s}' is used before initialization",
                            .{slot.name},
                        );
                        try self.diagnostics.append(.{
                            .func_name = try self.allocator.dupe(u8, func.name),
                            .block_name = try self.allocator.dupe(u8, blk.label),
                            .inst_idx = @intCast(idx),
                            .slot_name = try self.allocator.dupe(u8, slot.name),
                            .message = msg,
                        });
                    },
                    .store => {
                        if (inst.operands.len < 2) continue;
                        const d = prov.get(inst.operands[0]) orelse continue;
                        markWritten(
                            cur_state,
                            slot_base[d.slot],
                            slots.items[d.slot],
                            d.offset,
                            module.types.sizeOf(inst.ty),
                        );
                    },
                    else => {},
                }
            }
        }
    }
};

const testing = std.testing;

/// `struct User { id: i64, score: i64, active: i64 }`, three 8-byte fields at
/// offsets 0/8/16. The types own the name/fields/offsets allocations.
fn addUserType(mod: *bir.Module) !bir.TypeId {
    const alloc = mod.allocator;
    const t_i64 = try mod.types.scalarType(.i64);

    const fields = try alloc.alloc(bir.TypeId, 3);
    @memset(fields, t_i64);
    const offsets = try alloc.alloc(u32, 3);
    offsets[0] = 0;
    offsets[1] = 8;
    offsets[2] = 16;

    return mod.types.add(.{ .struct_type = .{
        .name = try alloc.dupe(u8, "User"),
        .fields = fields,
        .offsets = offsets,
        .size_val = 24,
        .alignment_val = 8,
    } });
}

fn emitInst(mod: *bir.Module, fid: bir.FunctionId, bid: bir.BlockId, inst: bir.Inst) !bir.ValueId {
    return mod.addInst(fid, bid, inst);
}

fn emitConst(mod: *bir.Module, fid: bir.FunctionId, bid: bir.BlockId, t_i64: bir.TypeId, value: i64) !bir.ValueId {
    return emitInst(mod, fid, bid, .{
        .op = .@"const",
        .ty = t_i64,
        .result = 0,
        .operands = &.{},
        .data = .{ .const_data = .{ .int = value } },
    });
}

/// `add slot, offset`, which is how the frontend materializes a field address.
fn emitFieldAddr(mod: *bir.Module, fid: bir.FunctionId, bid: bir.BlockId, t_i64: bir.TypeId, slot: bir.ValueId, offset: i64) !bir.ValueId {
    const off = try emitConst(mod, fid, bid, t_i64, offset);
    return emitInst(mod, fid, bid, .{
        .op = .add,
        .ty = t_i64,
        .result = 0,
        .operands = try mod.allocator.dupe(bir.ValueId, &.{ slot, off }),
        .data = .{ .none = {} },
    });
}

fn writeField(
    mod: *bir.Module,
    fid: bir.FunctionId,
    bid: bir.BlockId,
    t_i64: bir.TypeId,
    slot: bir.ValueId,
    offset: i64,
    value: i64,
) !void {
    const val = try emitConst(mod, fid, bid, t_i64, value);
    const addr = try emitFieldAddr(mod, fid, bid, t_i64, slot, offset);
    _ = try emitInst(mod, fid, bid, .{
        .op = .store,
        .ty = t_i64,
        .result = 0,
        .operands = try mod.allocator.dupe(bir.ValueId, &.{ addr, val }),
        .data = .{ .none = {} },
    });
}

fn emitAlloca(mod: *bir.Module, fid: bir.FunctionId, bid: bir.BlockId, ty: bir.TypeId, name: []const u8) !bir.ValueId {
    const value = try emitInst(mod, fid, bid, .{
        .op = .alloca,
        .ty = ty,
        .result = 0,
        .operands = &.{},
        .data = .{ .none = {} },
    });
    try mod.getFunctionMut(fid).value_debug_names.put(value, try mod.allocator.dupe(u8, name));
    return value;
}

fn emitWholeStructLoad(mod: *bir.Module, fid: bir.FunctionId, bid: bir.BlockId, ty: bir.TypeId, slot: bir.ValueId) !bir.ValueId {
    return emitInst(mod, fid, bid, .{
        .op = .load,
        .ty = ty,
        .result = 0,
        .operands = try mod.allocator.dupe(bir.ValueId, &.{slot}),
        .data = .{ .none = {} },
    });
}

fn emitRet(mod: *bir.Module, fid: bir.FunctionId, bid: bir.BlockId, t_void: bir.TypeId) !void {
    _ = try emitInst(mod, fid, bid, .{
        .op = .ret,
        .ty = t_void,
        .result = 0,
        .operands = &.{},
        .data = .{ .none = {} },
    });
}

const Probe = struct {
    mod: bir.Module,
    t_i64: bir.TypeId,
    t_void: bir.TypeId,
    t_user: bir.TypeId,
    fid: bir.FunctionId,
};

fn newProbe(alloc: std.mem.Allocator, name: []const u8) !Probe {
    var mod = bir.Module.init(alloc);
    errdefer mod.deinit();
    const t_void = try mod.types.voidType();
    const t_i64 = try mod.types.scalarType(.i64);
    const t_user = try addUserType(&mod);
    const fid = try mod.addFunction(name, t_void, .internal);
    return .{ .mod = mod, .t_i64 = t_i64, .t_void = t_void, .t_user = t_user, .fid = fid };
}

fn runChecker(alloc: std.mem.Allocator, mod: *bir.Module) !std.ArrayList(InitDiagnostic) {
    var checker = InitChecker.init(alloc);
    errdefer checker.deinit();
    try checker.checkModule(mod);
    return checker.diagnostics;
}

test "InitChecker: struct with every field written is initialized" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    const user = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "user");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 0, 1);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 8, 500);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 16, 1);
    _ = try emitWholeStructLoad(&probe.mod, probe.fid, entry, probe.t_user, user);
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "InitChecker: one missing field keeps the struct uninitialized" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    const user = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "user");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 0, 1);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 8, 500);
    _ = try emitWholeStructLoad(&probe.mod, probe.fid, entry, probe.t_user, user);
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqualStrings("user", diags.items[0].slot_name);
}

test "InitChecker: a field written only inside one branch does not count" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    const then_bb = try probe.mod.addBlock(probe.fid, "then");
    const else_bb = try probe.mod.addBlock(probe.fid, "else");
    const join = try probe.mod.addBlock(probe.fid, "join");

    const user = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "user");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 0, 1);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 8, 500);

    const cond = try emitConst(&probe.mod, probe.fid, entry, probe.t_i64, 1);
    _ = try emitInst(&probe.mod, probe.fid, entry, .{
        .op = .cond_br,
        .ty = probe.t_void,
        .result = 0,
        .operands = &.{},
        .data = .{ .cond_branch = .{ .cond = cond, .then_block = then_bb, .else_block = else_bb } },
    });

    try writeField(&probe.mod, probe.fid, then_bb, probe.t_i64, user, 16, 1);
    _ = try emitInst(&probe.mod, probe.fid, then_bb, .{
        .op = .br,
        .ty = probe.t_void,
        .result = 0,
        .operands = &.{},
        .data = .{ .block_target = join },
    });
    _ = try emitInst(&probe.mod, probe.fid, else_bb, .{
        .op = .br,
        .ty = probe.t_void,
        .result = 0,
        .operands = &.{},
        .data = .{ .block_target = join },
    });

    _ = try emitWholeStructLoad(&probe.mod, probe.fid, join, probe.t_user, user);
    try emitRet(&probe.mod, probe.fid, join, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqualStrings("user", diags.items[0].slot_name);
    try testing.expectEqualStrings("join", diags.items[0].block_name);
}

test "InitChecker: writing the same field repeatedly is fine" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    const user = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "user");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 0, 1);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 0, 7);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 8, 500);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 16, 1);
    _ = try emitWholeStructLoad(&probe.mod, probe.fid, entry, probe.t_user, user);
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "InitChecker: several struct variables are tracked independently" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    const full = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "a");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, full, 0, 1);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, full, 8, 2);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, full, 16, 1);

    const partial = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "b");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, partial, 0, 1);

    _ = try emitWholeStructLoad(&probe.mod, probe.fid, entry, probe.t_user, full);
    _ = try emitWholeStructLoad(&probe.mod, probe.fid, entry, probe.t_user, partial);
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqualStrings("b", diags.items[0].slot_name);
}

test "InitChecker: reading a single unwritten field is reported" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    const user = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "user");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 0, 1);

    const score_addr = try emitFieldAddr(&probe.mod, probe.fid, entry, probe.t_i64, user, 8);
    _ = try emitInst(&probe.mod, probe.fid, entry, .{
        .op = .load,
        .ty = probe.t_i64,
        .result = 0,
        .operands = try probe.mod.allocator.dupe(bir.ValueId, &.{score_addr}),
        .data = .{ .none = {} },
    });
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqualStrings("user", diags.items[0].slot_name);
}

test "InitChecker: padding between fields is never demanded" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    // A User whose declared size (24) exceeds the sum of nothing: field writes
    // cover 0..8, 8..16 and 16..24, leaving no padding, so a struct read is fine.
    const user = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_user, "user");
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 0, 1);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 8, 500);
    try writeField(&probe.mod, probe.fid, entry, probe.t_i64, user, 16, 1);
    _ = try emitWholeStructLoad(&probe.mod, probe.fid, entry, probe.t_user, user);
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "InitChecker: scalar slots keep the any-store rule" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    const slot = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_i64, "result");
    const val = try emitConst(&probe.mod, probe.fid, entry, probe.t_i64, 42);
    _ = try emitInst(&probe.mod, probe.fid, entry, .{
        .op = .store,
        .ty = probe.t_i64,
        .result = 0,
        .operands = try probe.mod.allocator.dupe(bir.ValueId, &.{ slot, val }),
        .data = .{ .none = {} },
    });
    _ = try emitWholeStructLoad(&probe.mod, probe.fid, entry, probe.t_i64, slot);
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "InitChecker: an unread scalar slot is never reported" {
    var probe = try newProbe(testing.allocator, "main");
    defer probe.mod.deinit();

    const entry = try probe.mod.addBlock(probe.fid, "entry");
    _ = try emitAlloca(&probe.mod, probe.fid, entry, probe.t_i64, "result");
    try emitRet(&probe.mod, probe.fid, entry, probe.t_void);

    const diags = try runChecker(testing.allocator, &probe.mod);
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.func_name);
            testing.allocator.free(d.block_name);
            testing.allocator.free(d.slot_name);
            testing.allocator.free(d.message);
        }
        diags.deinit();
    }
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}
