const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../../analysis/cfg/cfg.zig");
const Module = bir.Module;
const Op = bir.Op;
const Inst = bir.Inst;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const NO_VALUE = bir.NO_VALUE;
const PreservedAnalyses = bir.PreservedAnalyses;
const INVALID_ID = bir.INVALID_ID;

pub const SCCPPass = bir.Pass{
    .name = "sccp",
    .run = runSCCP,
};

// ─── Lattice: Top (undefined) | Const | Bottom (overdefined) ───

const Lattice = union(enum) {
    top: void,
    int_const: i64,
    bool_const: bool,
    bottom: void,

    fn meet(a: Lattice, b: Lattice) Lattice {
        if (a == .bottom or b == .bottom) return .{ .bottom = {} };
        if (a == .top) return b;
        if (b == .top) return a;
        if (a == .int_const and b == .int_const) {
            if (a.int_const == b.int_const) return a;
            return .{ .bottom = {} };
        }
        if (a == .bool_const and b == .bool_const) {
            if (a.bool_const == b.bool_const) return a;
            return .{ .bottom = {} };
        }
        return .{ .bottom = {} };
    }

    fn isConstant(self: Lattice) bool {
        return self == .int_const or self == .bool_const;
    }
};

// ─── SCCP Solver ───

const InstOfEntry = struct { block: BlockId, idx: u32 };

const SCCPSolver = struct {
    allocator: Allocator,
    func: *bir.Function,
    cfg: *const bir_cfg.CFG,

    // Value lattice: indexed by ValueId - 1
    lattice: std.ArrayList(Lattice),

    // Block executability
    executable: std.ArrayList(bool),

    // Worklists
    value_worklist: std.ArrayList(ValueId),
    edge_worklist: std.ArrayList(bir_cfg.Edge),
    term_worklist: std.ArrayList(BlockId),

    // Instructions that need re-evaluation, indexed by ValueId - 1
    inst_of: std.ArrayList(InstOfEntry),

    fn init(allocator: Allocator, func: *bir.Function, cfg: *const bir_cfg.CFG) !SCCPSolver {
        const num_values = func.value_info.items.len;
        var lattice = std.ArrayList(Lattice).init(allocator);
        var inst_of = std.ArrayList(InstOfEntry).init(allocator);
        var executable = std.ArrayList(bool).init(allocator);

        try lattice.resize(num_values);
        for (lattice.items) |*l| l.* = .{ .top = {} };

        try inst_of.resize(num_values);
        for (inst_of.items) |*io| io.* = .{ .block = INVALID_ID, .idx = INVALID_ID };

        try executable.resize(func.blocks.items.len);
        for (executable.items) |*e| e.* = false;

        // Map value definitions to instructions
        for (func.blocks.items, 0..) |*block, bi| {
            for (block.instrs.items, 0..) |inst, ii| {
                if (inst.result != NO_VALUE and inst.result <= num_values) {
                    inst_of.items[inst.result - 1] = .{ .block = @as(BlockId, @intCast(bi)), .idx = @as(u32, @intCast(ii)) };
                }
            }
        }

        // Mark parameters as bottom (we don't know their values)
        for (func.param_values) |pv| {
            if (pv != NO_VALUE and pv <= num_values) {
                lattice.items[pv - 1] = .{ .bottom = {} };
            }
        }

        return .{
            .allocator = allocator,
            .func = func,
            .cfg = cfg,
            .lattice = lattice,
            .executable = executable,
            .value_worklist = std.ArrayList(ValueId).init(allocator),
            .edge_worklist = std.ArrayList(bir_cfg.Edge).init(allocator),
            .term_worklist = std.ArrayList(BlockId).init(allocator),
            .inst_of = inst_of,
        };
    }

    fn deinit(self: *SCCPSolver) void {
        self.lattice.deinit();
        self.executable.deinit();
        self.value_worklist.deinit();
        self.edge_worklist.deinit();
        self.term_worklist.deinit();
        self.inst_of.deinit();
    }

    fn run(self: *SCCPSolver) !void {
        self.executable.items[0] = true;
        try self.addBlockInstructions(0);

        while (self.value_worklist.items.len > 0 or self.edge_worklist.items.len > 0 or self.term_worklist.items.len > 0) {
            while (self.edge_worklist.items.len > 0) {
                const edge = self.edge_worklist.pop().?;
                if (!self.executable.items[edge.to]) {
                    self.executable.items[edge.to] = true;
                    try self.addBlockInstructions(edge.to);
                }
            }

            while (self.value_worklist.items.len > 0) {
                const vid = self.value_worklist.pop().?;
                if (vid == NO_VALUE or vid == 0) continue;
                if (vid > self.lattice.items.len) continue;

                const def = self.inst_of.items[vid - 1];
                if (def.block == INVALID_ID) continue;
                if (!self.executable.items[def.block]) continue;

                const block = &self.func.blocks.items[def.block];
                if (def.idx >= block.instrs.items.len) continue;
                const inst = &block.instrs.items[def.idx];

                const old_lat = self.lattice.items[vid - 1];
                const new_lat = self.evaluateInst(inst);

                if (new_lat == .bottom and old_lat != .bottom) {
                    self.lattice.items[vid - 1] = .{ .bottom = {} };
                    self.notifyUses(vid);
                } else if (new_lat.isConstant() and old_lat == .top) {
                    self.lattice.items[vid - 1] = new_lat;
                    self.notifyUses(vid);
                }
            }

            while (self.term_worklist.items.len > 0) {
                const bid = self.term_worklist.pop().?;
                if (!self.executable.items[bid]) continue;
                const block = &self.func.blocks.items[bid];
                if (block.instrs.items.len == 0) continue;
                const last = block.instrs.items[block.instrs.items.len - 1];
                try self.addTerminatorEdges(bid, last);
            }
        }
    }

    fn notifyUses(self: *SCCPSolver, vid: ValueId) void {
        const vi = self.func.getValueInfo(vid);
        for (vi.uses.items) |user_val| {
            if (user_val == NO_VALUE or user_val == 0) continue;
            if (user_val > self.inst_of.items.len) continue;
            const def = self.inst_of.items[user_val - 1];
            if (def.block != INVALID_ID and self.executable.items[def.block]) {
                self.value_worklist.append(user_val) catch {};
            }
        }
        // Also re-evaluate terminators that might use this value
        for (self.func.blocks.items, 0..) |*block, bi| {
            if (block.instrs.items.len == 0) continue;
            const last = block.instrs.items[block.instrs.items.len - 1];
            if (last.op == .cond_br) {
                if (last.data.cond_branch.cond == vid) {
                    self.term_worklist.append(@as(BlockId, @intCast(bi))) catch {};
                }
            }
        }
    }

    fn addBlockInstructions(self: *SCCPSolver, bid: BlockId) !void {
        const block = &self.func.blocks.items[bid];
        for (block.instrs.items) |inst| {
            if (inst.result != NO_VALUE and inst.result <= self.lattice.items.len) {
                const old_lat = self.lattice.items[inst.result - 1];
                if (old_lat == .top) {
                    self.value_worklist.append(inst.result) catch {};
                }
            }
        }
        // Defer terminator edge addition until terminator is evaluated
        self.term_worklist.append(bid) catch {};
    }

    fn addTerminatorEdges(self: *SCCPSolver, bid: BlockId, inst: Inst) !void {
        switch (inst.op) {
            .br => {
                const target = inst.data.block_target;
                try self.edge_worklist.append(.{ .from = bid, .to = target });
            },
            .cond_br => {
                const cb = inst.data.cond_branch;
                const cond_lat = self.getLattice(cb.cond);
                if (cond_lat == .bool_const) {
                    if (cond_lat.bool_const) {
                        try self.edge_worklist.append(.{ .from = bid, .to = cb.then_block });
                    } else {
                        try self.edge_worklist.append(.{ .from = bid, .to = cb.else_block });
                    }
                } else {
                    try self.edge_worklist.append(.{ .from = bid, .to = cb.then_block });
                    try self.edge_worklist.append(.{ .from = bid, .to = cb.else_block });
                }
            },
            else => {},
        }
    }

    fn evaluateInst(self: *SCCPSolver, inst: *const Inst) Lattice {
        switch (inst.op) {
            .@"const" => {
                return switch (inst.data) {
                    .const_data => |cd| switch (cd) {
                        .int => |v| .{ .int_const = v },
                        .bool => |v| .{ .bool_const = v },
                        .float => .{ .bottom = {} },
                        .undefined, .zero => .{ .top = {} },
                    },
                    else => .{ .top = {} },
                };
            },
            .add => return self.evalBinaryInt(inst, .add),
            .sub => return self.evalBinaryInt(inst, .sub),
            .mul => return self.evalBinaryInt(inst, .mul),
            .div => return self.evalBinaryInt(inst, .div),
            .mod => return self.evalBinaryInt(inst, .mod),
            .max => return self.evalBinaryInt(inst, .max),
            .min => return self.evalBinaryInt(inst, .min),
            .neg => return self.evalUnaryInt(inst, .neg),
            .not => return self.evalUnaryInt(inst, .not),
            .and_op => return self.evalBinaryInt(inst, .and_op),
            .or_op => return self.evalBinaryInt(inst, .or_op),
            .xor_op => return self.evalBinaryInt(inst, .xor_op),
            .eq, .ne, .lt, .le, .gt, .ge => return self.evalComparison(inst),
            .phi => return self.evalPhi(inst),
            .select => {
                if (inst.operands.len < 3) return .{ .bottom = {} };
                const cond = self.getLattice(inst.operands[0]);
                if (cond == .bool_const) {
                    return self.getLattice(if (cond.bool_const) inst.operands[1] else inst.operands[2]);
                }
                if (cond == .top) return .{ .top = {} };
                return .{ .bottom = {} };
            },
            else => return .{ .bottom = {} },
        }
    }

    fn evalBinaryInt(self: *SCCPSolver, inst: *const Inst, comptime op: Op) Lattice {
        if (inst.operands.len < 2) return .{ .bottom = {} };
        const a = self.getLattice(inst.operands[0]);
        const b = self.getLattice(inst.operands[1]);

        if (a == .bottom or b == .bottom) return .{ .bottom = {} };
        if (a == .top or b == .top) return .{ .top = {} };

        if (a != .int_const or b != .int_const) return .{ .bottom = {} };

        const result: i64 = switch (op) {
            .add => a.int_const +% b.int_const,
            .sub => a.int_const -% b.int_const,
            .mul => a.int_const *% b.int_const,
            .div => if (b.int_const != 0) @divTrunc(a.int_const, b.int_const) else return .{ .bottom = {} },
            .mod => if (b.int_const != 0) @rem(a.int_const, b.int_const) else return .{ .bottom = {} },
            .and_op => a.int_const & b.int_const,
            .or_op => a.int_const | b.int_const,
            .xor_op => a.int_const ^ b.int_const,
            .max => if (a.int_const > b.int_const) a.int_const else b.int_const,
            .min => if (a.int_const < b.int_const) a.int_const else b.int_const,
            else => return .{ .bottom = {} },
        };
        return .{ .int_const = result };
    }

    fn evalUnaryInt(self: *SCCPSolver, inst: *const Inst, comptime op: Op) Lattice {
        if (inst.operands.len < 1) return .{ .bottom = {} };
        const a = self.getLattice(inst.operands[0]);
        if (a == .bottom) return .{ .bottom = {} };
        if (a == .top) return .{ .top = {} };
        if (a != .int_const) return .{ .bottom = {} };

        return switch (op) {
            .neg => .{ .int_const = -%a.int_const },
            .not => .{ .int_const = ~a.int_const },
            else => .{ .bottom = {} },
        };
    }

    fn evalComparison(self: *SCCPSolver, inst: *const Inst) Lattice {
        if (inst.operands.len < 2) return .{ .bottom = {} };
        const a = self.getLattice(inst.operands[0]);
        const b = self.getLattice(inst.operands[1]);

        if (a == .bottom or b == .bottom) return .{ .bottom = {} };
        if (a == .top or b == .top) return .{ .top = {} };
        if (a != .int_const or b != .int_const) return .{ .bottom = {} };

        const result: bool = switch (inst.op) {
            .eq => a.int_const == b.int_const,
            .ne => a.int_const != b.int_const,
            .lt => a.int_const < b.int_const,
            .le => a.int_const <= b.int_const,
            .gt => a.int_const > b.int_const,
            .ge => a.int_const >= b.int_const,
            else => return .{ .bottom = {} },
        };
        return .{ .bool_const = result };
    }

    fn evalPhi(self: *SCCPSolver, inst: *const Inst) Lattice {
        if (inst.data != .phi_incoming) return .{ .bottom = {} };
        const incoming = inst.data.phi_incoming;

        var result: Lattice = .{ .top = {} };
        for (incoming) |inc| {
            if (!self.executable.items[inc.block]) continue;
            const inc_lat = self.getLattice(inc.value);
            result = Lattice.meet(result, inc_lat);
            if (result == .bottom) break;
        }
        return result;
    }

    fn getLattice(self: *const SCCPSolver, vid: ValueId) Lattice {
        if (vid == NO_VALUE or vid == 0) return .{ .top = {} };
        if (vid > self.lattice.items.len) return .{ .bottom = {} };
        return self.lattice.items[vid - 1];
    }
};

// ─── Apply results ───

fn applyResults(func: *bir.Function, solver: *const SCCPSolver) !bool {
    var changed = false;
    var num_folded: u32 = 0;

    for (func.blocks.items) |*block| {
        var i: usize = 0;
        while (i < block.instrs.items.len) {
            const inst = &block.instrs.items[i];
            if (inst.result == NO_VALUE or inst.result == 0) {
                i += 1;
                continue;
            }
            if (inst.result > solver.lattice.items.len) {
                i += 1;
                continue;
            }

            const lat = solver.lattice.items[inst.result - 1];

            if (lat == .int_const and inst.op != .@"const") {
                // Fold to constant
                inst.deinit(func.allocator);
                const ops = try func.allocator.dupe(ValueId, &.{});
                inst.op = .@"const";
                inst.ty = bir.types.INVALID_TYPE;
                inst.operands = ops;
                inst.data = .{ .const_data = .{ .int = lat.int_const } };
                changed = true;
                num_folded += 1;
            } else if (lat == .bool_const and inst.op != .@"const") {
                inst.deinit(func.allocator);
                const ops = try func.allocator.dupe(ValueId, &.{});
                inst.op = .@"const";
                inst.ty = bir.types.INVALID_TYPE;
                inst.operands = ops;
                inst.data = .{ .const_data = .{ .bool = lat.bool_const } };
                changed = true;
                num_folded += 1;
            }

            i += 1;
        }
    }

    // Remove unreachable blocks and remap all block references
    // Step 1: Build remap table (old_index -> new_index, or null for removed)
    var remap = std.ArrayList(?usize).init(func.allocator);
    defer remap.deinit();
    try remap.resize(func.blocks.items.len);

    var new_index: usize = 0;
    for (0..func.blocks.items.len) |bi| {
        if (bi == 0 or solver.executable.items[bi]) {
            remap.items[bi] = new_index;
            new_index += 1;
        } else {
            remap.items[bi] = null;
        }
    }

    // Step 2: Fix terminators in executable predecessors (cond_br → br)
    for (func.blocks.items) |*block| {
        if (block.instrs.items.len == 0) continue;
        const last = &block.instrs.items[block.instrs.items.len - 1];
        switch (last.op) {
            .cond_br => {
                const cb = last.data.cond_branch;
                if (remap.items[cb.then_block] == null and remap.items[cb.else_block] != null) {
                    last.op = .br;
                    last.data = .{ .block_target = cb.else_block };
                    changed = true;
                } else if (remap.items[cb.else_block] == null and remap.items[cb.then_block] != null) {
                    last.op = .br;
                    last.data = .{ .block_target = cb.then_block };
                    changed = true;
                }
            },
            else => {},
        }
    }

    // Step 3: Clean phi incoming — remove entries that reference dead blocks
    for (func.blocks.items) |*block| {
        for (block.instrs.items) |*inst| {
            if (inst.op != .phi) continue;
            var new_incoming = std.ArrayList(bir.PhiIncoming).init(func.allocator);
            for (inst.data.phi_incoming) |inc| {
                if (remap.items[inc.block] != null) {
                    try new_incoming.append(.{ .value = inc.value, .block = inc.block });
                }
            }
            func.allocator.free(inst.data.phi_incoming);
            inst.data.phi_incoming = try new_incoming.toOwnedSlice();
        }
    }

    // Step 4: Remove dead blocks from the list
    var wi: usize = func.blocks.items.len;
    while (wi > 0) {
        wi -= 1;
        if (wi == 0) continue; // never remove entry
        if (remap.items[wi] == null) {
            func.blocks.items[wi].deinit(func.allocator);
            _ = func.blocks.orderedRemove(wi);
            changed = true;
        }
    }

    // Step 5: Remap all block references in terminators, phi incoming, and value_info
    for (func.blocks.items) |*block| {
        if (block.instrs.items.len == 0) continue;
        const last = &block.instrs.items[block.instrs.items.len - 1];
        switch (last.op) {
            .br => {
                const old_target = last.data.block_target;
                last.data = .{ .block_target = @intCast(remap.items[old_target] orelse 0) };
            },
            .cond_br => {
                const cb = last.data.cond_branch;
                last.data = .{ .cond_branch = .{
                    .cond = cb.cond,
                    .then_block = @intCast(remap.items[cb.then_block] orelse 0),
                    .else_block = @intCast(remap.items[cb.else_block] orelse 0),
                } };
            },
            else => {},
        }
        for (block.instrs.items) |*inst| {
            if (inst.op != .phi) continue;
            for (inst.data.phi_incoming) |*inc| {
                inc.block = @intCast(remap.items[inc.block] orelse 0);
            }
        }
    }

    // Step 6: Remap value_info def positions — block indices shifted after removal
    // Also rebuild def for folded constants since instruction ops changed
    for (func.value_info.items) |*vi| {
        const old_block = vi.def.block;
        if (old_block < func.blocks.items.len + remap.items.len) {
            if (old_block < remap.items.len) {
                if (remap.items[old_block]) |new_blk| {
                    vi.def.block = @intCast(new_blk);
                } else {
                    vi.def.block = 0; // was in dead block, mark as entry (safe)
                }
            }
        }
    }

    if (num_folded > 0) {
        if (@import("builtin").mode == .Debug) {
            std.debug.print("  SCCP: folded {d} values to constants\n", .{num_folded});
        }
    }

    return changed;
}

// ─── Pass entry point ───

fn runSCCP(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    const allocator = ctx.allocator;
    for (module.functions.items, 0..) |*func, fid| {
        if (func.blocks.items.len == 0) continue;
        const func_id = @as(bir.FunctionId, @intCast(fid));

        const cfg = try ctx.analysis.getCFG(func_id);

        var solver = try SCCPSolver.init(allocator, func, cfg);
        defer solver.deinit();

        try solver.run();

        _ = try applyResults(func, &solver);
    }
    return PreservedAnalyses.none();
}
