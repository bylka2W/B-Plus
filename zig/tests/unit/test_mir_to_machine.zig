const std = @import("std");
const mir = @import("../../src/compiler/backend/mir/mir.zig");
const machine = @import("../../src/compiler/backend/machine/machine.zig");
const mir_lower = machine.mir_lower;

pub fn main() !void {
    try testRetConst();
    try testSimpleAdd();
    try testSub();
    try testBranch();
    try testMultipleBlocks();
    try testAllocaLoadStore();
    try testPhiSkipped();
    try testMulDiv();
    try testComparison();
    try testCall();
    try testRegallocSimple();
    try testPlanStateMachine();

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("\n=== ALL MIR→Machine IR TESTS PASSED ===\n");
}

fn addBlock(alloc: std.mem.Allocator, func: *mir.MFunction, label: []const u8) !*mir.MBlock {
    const blk = mir.MBlock{
        .label = try alloc.dupe(u8, label),
        .instrs = std.ArrayList(mir.MInst).init(alloc),
    };
    try func.blocks.append(blk);
    return &func.blocks.items[func.blocks.items.len - 1];
}

fn testRetConst() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testRetConst ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("main");
    try func.putVReg(0, .i64);

    const blk = try addBlock(alloc, func, "entry");
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 0 }, .src = .{ .imm = 42 } } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 0 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    try std.testing.expectEqual(@as(usize, 1), mmod_out.functions.items.len);
    const out_func = &mmod_out.functions.items[0];

    try std.testing.expectEqual(@as(usize, 1), out_func.blocks.items.len);
    const out_blk = &out_func.blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), out_blk.instrs.items.len);

    const mov = out_blk.instrs.items[0];
    try std.testing.expect(mov == .mov);
    try std.testing.expect(mov.mov.dst == .vreg);
    try std.testing.expectEqual(@as(u32, 0), mov.mov.dst.vreg.id);
    try std.testing.expectEqual(machine.RegClass.gpr, mov.mov.dst.vreg.class);
    try std.testing.expect(mov.mov.src == .imm);
    try std.testing.expectEqual(@as(i64, 42), mov.mov.src.imm);

    const ret = out_blk.instrs.items[1];
    try std.testing.expect(ret == .ret);
    try std.testing.expect(ret.ret == .value);
    try std.testing.expect(ret.ret.value == .vreg);
    try std.testing.expectEqual(@as(u32, 0), ret.ret.value.vreg.id);

    try stdout.writeAll("  PASS\n\n");
}

fn testSimpleAdd() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testSimpleAdd ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("add_test");
    try func.putVReg(0, .i64);
    try func.putVReg(1, .i64);
    try func.putVReg(2, .i64);

    const blk = try addBlock(alloc, func, "entry");
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 0 }, .src = .{ .imm = 10 } } });
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 1 }, .src = .{ .imm = 20 } } });
    try blk.instrs.append(.{ .add = .{ .dst = .{ .vreg = 2 }, .src = .{ .vreg = 1 } } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 2 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_blk = &mmod_out.functions.items[0].blocks.items[0];
    try std.testing.expectEqual(@as(usize, 4), out_blk.instrs.items.len);

    const add_inst = out_blk.instrs.items[2];
    try std.testing.expect(add_inst == .add);
    try std.testing.expect(add_inst.add.dst == .vreg);
    try std.testing.expectEqual(@as(u32, 2), add_inst.add.dst.vreg.id);
    try std.testing.expectEqual(machine.RegClass.gpr, add_inst.add.dst.vreg.class);
    try std.testing.expect(add_inst.add.src == .vreg);
    try std.testing.expectEqual(@as(u32, 1), add_inst.add.src.vreg.id);

    try stdout.writeAll("  PASS\n\n");
}

fn testSub() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testSub ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("sub_test");
    try func.putVReg(0, .i64);
    try func.putVReg(1, .i64);

    const blk = try addBlock(alloc, func, "entry");
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 0 }, .src = .{ .imm = 100 } } });
    try blk.instrs.append(.{ .sub = .{ .dst = .{ .vreg = 0 }, .src = .{ .vreg = 1 } } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 0 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_blk = &mmod_out.functions.items[0].blocks.items[0];
    try std.testing.expectEqual(@as(usize, 3), out_blk.instrs.items.len);

    const sub_inst = out_blk.instrs.items[1];
    try std.testing.expect(sub_inst == .sub);

    try stdout.writeAll("  PASS\n\n");
}

fn testBranch() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testBranch ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("branch_test");

    const b0 = try addBlock(alloc, func, "entry");
    try b0.instrs.append(.{ .jmp = .{ .target = 1 } });

    const b1 = try addBlock(alloc, func, "target");
    try b1.instrs.append(.{ .ret = .void_ret });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_func = &mmod_out.functions.items[0];
    try std.testing.expectEqual(@as(usize, 2), out_func.blocks.items.len);

    const jmp = out_func.blocks.items[0].instrs.items[0];
    try std.testing.expect(jmp == .jmp);
    try std.testing.expectEqual(@as(u32, 1), jmp.jmp.target);

    const ret_inst = out_func.blocks.items[1].instrs.items[0];
    try std.testing.expect(ret_inst == .ret);
    try std.testing.expect(ret_inst.ret == .void_ret);

    try stdout.writeAll("  PASS\n\n");
}

fn testMultipleBlocks() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testMultipleBlocks ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("multi");
    try func.putVReg(0, .i1);

    const b0 = try addBlock(alloc, func, "entry");
    try b0.instrs.append(.{ .cmp_flags = .{ .a = .{ .imm = 1 }, .b = .{ .imm = 0 } } });
    try b0.instrs.append(.{ .jcc = .{ .cc = .ne, .target = 1 } });
    try b0.instrs.append(.{ .jmp = .{ .target = 2 } });

    const b1 = try addBlock(alloc, func, "then");
    try b1.instrs.append(.{ .ret = .{ .value = .{ .imm = 10 } } });

    const b2 = try addBlock(alloc, func, "else_blk");
    try b2.instrs.append(.{ .ret = .{ .value = .{ .imm = 20 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_func = &mmod_out.functions.items[0];
    try std.testing.expectEqual(@as(usize, 3), out_func.blocks.items.len);

    const entry = &out_func.blocks.items[0];
    try std.testing.expectEqual(@as(usize, 3), entry.instrs.items.len);

    const cf = entry.instrs.items[0];
    try std.testing.expect(cf == .cmp_flags);

    const jcc = entry.instrs.items[1];
    try std.testing.expect(jcc == .jcc);
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(jcc.jcc.cc));
    try std.testing.expectEqual(@as(u32, 1), jcc.jcc.target);

    const jmp = entry.instrs.items[2];
    try std.testing.expect(jmp == .jmp);

    try stdout.writeAll("  PASS\n\n");
}

fn testAllocaLoadStore() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testAllocaLoadStore ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("mem_test");
    try func.putVReg(0, .i64);
    try func.putVReg(1, .i64);

    const blk = try addBlock(alloc, func, "entry");
    try blk.instrs.append(.{ .alloca = .{ .dst = .{ .vreg = 0 }, .size = 8 } });
    try blk.instrs.append(.{ .store = .{ .ptr = .{ .vreg = 0 }, .src = .{ .imm = 42 }, .size = .u64 } });
    try blk.instrs.append(.{ .load = .{ .dst = .{ .vreg = 1 }, .ptr = .{ .vreg = 0 }, .size = .u64 } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 1 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_blk = &mmod_out.functions.items[0].blocks.items[0];
    try std.testing.expectEqual(@as(usize, 4), out_blk.instrs.items.len);

    const alloca = out_blk.instrs.items[0];
    try std.testing.expect(alloca == .alloca);
    try std.testing.expectEqual(@as(u32, 8), alloca.alloca.size);
    try std.testing.expect(alloca.alloca.dst == .vreg);
    try std.testing.expectEqual(machine.RegClass.gpr, alloca.alloca.dst.vreg.class);

    const store = out_blk.instrs.items[1];
    try std.testing.expect(store == .store);
    try std.testing.expect(store.store.ptr == .vreg);
    try std.testing.expect(store.store.src == .imm);

    const load = out_blk.instrs.items[2];
    try std.testing.expect(load == .load);
    try std.testing.expect(load.load.dst == .vreg);
    try std.testing.expect(load.load.ptr == .vreg);

    try stdout.writeAll("  PASS\n\n");
}

fn testPhiSkipped() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testPhiSkipped ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("phi_test");
    try func.putVReg(0, .i64);

    const b0 = try addBlock(alloc, func, "entry");
    try b0.instrs.append(.{ .jmp = .{ .target = 1 } });

    const incoming = try alloc.dupe(mir.PhiIncoming, &.{
        .{ .src = .{ .imm = 10 }, .pred_block = 0 },
        .{ .src = .{ .imm = 20 }, .pred_block = 2 },
    });
    const b1 = try addBlock(alloc, func, "merge");
    try b1.instrs.append(.{ .phi = .{ .dst = .{ .vreg = 0 }, .incoming = incoming } });
    try b1.instrs.append(.{ .ret = .{ .value = .{ .vreg = 0 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_blk = &mmod_out.functions.items[0].blocks.items[1];
    try std.testing.expectEqual(@as(usize, 1), out_blk.instrs.items.len);

    const ret = out_blk.instrs.items[0];
    try std.testing.expect(ret == .ret);

    try stdout.writeAll("  PASS\n\n");
}

fn testMulDiv() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testMulDiv ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("muldiv_test");
    try func.putVReg(0, .i64);
    try func.putVReg(1, .i64);
    try func.putVReg(2, .i64);
    try func.putVReg(3, .i64);
    try func.putVReg(4, .i64);

    const blk = try addBlock(alloc, func, "entry");
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 0 }, .src = .{ .imm = 6 } } });
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 1 }, .src = .{ .imm = 7 } } });
    try blk.instrs.append(.{ .imul = .{ .dst = .{ .vreg = 2 }, .src = .{ .vreg = 1 } } });
    try blk.instrs.append(.{ .idiv = .{ .dividend = .{ .vreg = 0 }, .divisor = .{ .vreg = 1 }, .quotient = .{ .vreg = 3 }, .remainder = .{ .vreg = 4 } } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 3 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_blk = &mmod_out.functions.items[0].blocks.items[0];
    const mul = out_blk.instrs.items[2];
    try std.testing.expect(mul == .imul);
    try std.testing.expect(mul.imul.dst == .vreg);
    try std.testing.expectEqual(machine.RegClass.gpr, mul.imul.dst.vreg.class);

    const div = out_blk.instrs.items[3];
    try std.testing.expect(div == .idiv);
    try std.testing.expect(div.idiv.quotient == .vreg);
    try std.testing.expect(div.idiv.remainder == .vreg);

    try stdout.writeAll("  PASS\n\n");
}

fn testComparison() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testComparison ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("cmp_test");
    try func.putVReg(0, .i64);
    try func.putVReg(1, .i64);
    try func.putVReg(2, .i64);

    const blk = try addBlock(alloc, func, "entry");
    try blk.instrs.append(.{ .cmp = .{ .cc = .lt, .a = .{ .vreg = 0 }, .b = .{ .vreg = 1 } } });
    try blk.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = 2 }, .cc = .lt } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 2 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_blk = &mmod_out.functions.items[0].blocks.items[0];
    const cmp = out_blk.instrs.items[0];
    try std.testing.expect(cmp == .cmp);
    try std.testing.expectEqual(@as(u8, 0xC), @intFromEnum(cmp.cmp.cc));
    try std.testing.expect(cmp.cmp.a == .vreg);
    try std.testing.expect(cmp.cmp.b == .vreg);

    try stdout.writeAll("  PASS\n\n");
}

fn testCall() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testCall ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("call_test");
    try func.putVReg(0, .i64);

    var args: [14]mir.MOperand = undefined;
    for (&args) |*a| a.* = .{ .imm = 0 };
    args[0] = .{ .imm = 42 };

    const blk = try addBlock(alloc, func, "entry");
    const call_name = try alloc.dupe(u8, "printf");
    try blk.instrs.append(.{ .call = .{ .name = call_name, .args = args, .arg_count = 1, .dst = .{ .vreg = 0 }, .is_void = false } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 0 } } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    const out_blk = &mmod_out.functions.items[0].blocks.items[0];
    const call = out_blk.instrs.items[0];
    try std.testing.expect(call == .call);
    try std.testing.expectEqualStrings("printf", call.call.name);
    try std.testing.expectEqual(@as(u32, 1), call.call.arg_count);
    try std.testing.expect(call.call.args[0] == .imm);
    try std.testing.expectEqual(@as(i64, 42), call.call.args[0].imm);

    try stdout.writeAll("  PASS\n\n");
}

fn testRegallocSimple() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testRegallocSimple ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("regalloc_test");
    try func.putVReg(0, .i64);
    try func.putVReg(1, .i64);
    try func.putVReg(2, .i64);

    const blk = try addBlock(alloc, func, "entry");
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 0 }, .src = .{ .imm = 10 } } });
    try blk.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 1 }, .src = .{ .imm = 20 } } });
    try blk.instrs.append(.{ .add = .{ .dst = .{ .vreg = 2 }, .src = .{ .vreg = 1 } } });
    try blk.instrs.append(.{ .ret = .{ .value = .{ .vreg = 2 } } });

    const regalloc = @import("../../src/compiler/backend/regalloc/regalloc.zig");
    const ra = try regalloc.allocRegs(func, alloc);

    try std.testing.expect(ra.regs.count() > 0);
    try stdout.print("  allocated {d} vregs to physical registers\n", .{ra.regs.count()});

    var it = ra.regs.iterator();
    while (it.next()) |kv| {
        try stdout.print("    v{d} -> reg {d}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
    }

    try stdout.writeAll("  PASS\n\n");
}

fn testPlanStateMachine() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("--- testPlanStateMachine ---\n");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mmod = mir.MModule.init(alloc);
    defer mmod.deinit();

    const func = try mmod.addFunction("test_sm");
    try func.putVReg(0, .i64);
    try func.putVReg(1, .i64);
    try func.putVReg(2, .i64);
    try func.putVReg(3, .i64);

    const blk0 = try addBlock(alloc, func, "entry");
    try blk0.instrs.append(.{ .state_init = .{ .initial_state = .{ .imm = 0 } } });
    try blk0.instrs.append(.{ .state_enter = .{ .state_id = .{ .imm = 0 } } });
    const cargs: [14]mir.MOperand = @splat(.{ .imm = 0 });
    try blk0.instrs.append(.{ .call = .{ .name = try alloc.dupe(u8, "state_A_entry"), .args = cargs, .arg_count = 0, .dst = .{ .imm = 0 }, .is_void = true } });
    try blk0.instrs.append(.{ .jmp = .{ .target = 1 } });

    const blk1 = try addBlock(alloc, func, "event_loop");
    try blk1.instrs.append(.{ .event_dispatch = .{ .dst = .{ .vreg = 1 }, .buf = .{ .vreg = 2 }, .size = .{ .vreg = 3 } } });
    try blk1.instrs.append(.{ .transition_check = .{ .result = .{ .vreg = 0 }, .event = .{ .vreg = 1 }, .event_id = 1 } });
    try blk1.instrs.append(.{ .guard_eval = .{ .result = .{ .vreg = 1 }, .lhs = .{ .imm = 0 }, .rhs = .{ .imm = 1 }, .cc = .eq } });
    try blk1.instrs.append(.{ .state_exit = .{ .state_id = .{ .imm = 0 } } });
    try blk1.instrs.append(.{ .jmp = .{ .target = 1 } });

    var mmod_out = try mir_lower.lowerModule(&mmod, alloc);
    defer mmod_out.deinit();

    try std.testing.expectEqual(@as(usize, 1), mmod_out.functions.items.len);
    const out_func = &mmod_out.functions.items[0];

    try std.testing.expectEqual(@as(usize, 2), out_func.blocks.items.len);

    const out_blk0 = &out_func.blocks.items[0];
    try std.testing.expectEqual(@as(usize, 4), out_blk0.instrs.items.len);
    try std.testing.expect(out_blk0.instrs.items[0] == .state_init);
    try std.testing.expect(out_blk0.instrs.items[0].state_init.initial_state == .imm);
    try std.testing.expectEqual(@as(i64, 0), out_blk0.instrs.items[0].state_init.initial_state.imm);
    try std.testing.expect(out_blk0.instrs.items[1] == .state_enter);
    try std.testing.expectEqual(@as(i64, 0), out_blk0.instrs.items[1].state_enter.state_id.imm);

    const out_blk1 = &out_func.blocks.items[1];
    try std.testing.expect(out_blk1.instrs.items[0] == .event_dispatch);
    try std.testing.expect(out_blk1.instrs.items[1] == .transition_check);
    try std.testing.expect(out_blk1.instrs.items[1].transition_check.event_id == 1);
    try std.testing.expect(out_blk1.instrs.items[2] == .guard_eval);
    try std.testing.expect(out_blk1.instrs.items[2].guard_eval.cc == .eq);
    try std.testing.expect(out_blk1.instrs.items[3] == .state_exit);

    try stdout.writeAll("  PASS\n\n");
}
