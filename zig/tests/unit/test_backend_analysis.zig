const std = @import("std");
const backend = @import("bir_backend");
const bir = backend.bir;
const bir_cfg = backend.bir_cfg;
const bir_dominators = backend.bir_dominators;
const bir_loops = backend.bir_loops;
const bir_analysis = backend.bir_analysis;
const bir_passes = backend.bir_passes;
const bir_verify = backend.bir_verify;
const bir_mem2reg = backend.bir_mem2reg;
const bir_cfgsimplify = backend.bir_cfgsimplify;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    try testLinearCFG(alloc, stdout);
    try testIfElseCFG(alloc, stdout);
    try testLoopCFG(alloc, stdout);
    try testDominators(alloc, stdout);
    try testDominanceFrontiers(alloc, stdout);
    try testCFGValidation(alloc, stdout);
    try testConstantFolding(alloc, stdout);
    try testDCE(alloc, stdout);
    try testFullPipeline(alloc, stdout);
    try testMem2Reg(alloc, stdout);
    try testCFGSimplify(alloc, stdout);

    try stdout.print("\n=== ALL TESTS PASSED ===\n", .{});
}

// ─── Helper: build BIR directly ───

fn buildSimpleAddModule(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);

    const func_id = try mod.addFunction("add_test", try mod.types.voidType(), .internal);
    const b0 = try mod.addBlock(func_id, "entry");

    const c10 = try mod.addInst(func_id, b0, .{
        .op = .@"const",
        .ty = try mod.types.scalarType(.i64),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .const_data = .{ .int = 10 } },
    });
    const c20 = try mod.addInst(func_id, b0, .{
        .op = .@"const",
        .ty = try mod.types.scalarType(.i64),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .const_data = .{ .int = 20 } },
    });
    const sum = try mod.addInst(func_id, b0, .{
        .op = .add,
        .ty = try mod.types.scalarType(.i64),
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ c10, c20 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b0, .{
        .op = .ret,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{sum}),
        .data = .{ .none = {} },
    });

    return mod;
}

fn buildIfElseModule(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);

    const func_id = try mod.addFunction("ifelse", try mod.types.voidType(), .internal);
    const b0 = try mod.addBlock(func_id, "entry");
    const b1 = try mod.addBlock(func_id, "if.then");
    const b2 = try mod.addBlock(func_id, "if.else");
    const b3 = try mod.addBlock(func_id, "if.merge");

    const c1 = try mod.addInst(func_id, b0, .{
        .op = .@"const",
        .ty = try mod.types.scalarType(.i1),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .const_data = .{ .bool = true } },
    });
    _ = try mod.addInst(func_id, b0, .{
        .op = .cond_br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .cond_branch = .{ .cond = c1, .then_block = b1, .else_block = b2 } },
    });

    const c10 = try mod.addInst(func_id, b1, .{
        .op = .@"const",
        .ty = try mod.types.scalarType(.i64),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .const_data = .{ .int = 10 } },
    });
    _ = try mod.addInst(func_id, b1, .{
        .op = .br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .block_target = b3 },
    });

    const c20 = try mod.addInst(func_id, b2, .{
        .op = .@"const",
        .ty = try mod.types.scalarType(.i64),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .const_data = .{ .int = 20 } },
    });
    _ = try mod.addInst(func_id, b2, .{
        .op = .br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .block_target = b3 },
    });

    _ = try mod.addInst(func_id, b3, .{
        .op = .ret,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .none = {} },
    });

    _ = c10;
    _ = c20;
    return mod;
}

fn buildLoopModule(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);

    const func_id = try mod.addFunction("loop", try mod.types.voidType(), .internal);
    const b0 = try mod.addBlock(func_id, "entry");
    const b1 = try mod.addBlock(func_id, "while.header");
    const b2 = try mod.addBlock(func_id, "while.body");
    const b3 = try mod.addBlock(func_id, "while.exit");

    _ = try mod.addInst(func_id, b0, .{
        .op = .br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .block_target = b1 },
    });

    const c1 = try mod.addInst(func_id, b1, .{
        .op = .@"const",
        .ty = try mod.types.scalarType(.i1),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .const_data = .{ .bool = true } },
    });
    _ = try mod.addInst(func_id, b1, .{
        .op = .cond_br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .cond_branch = .{ .cond = c1, .then_block = b2, .else_block = b3 } },
    });

    _ = try mod.addInst(func_id, b2, .{
        .op = .br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .block_target = b1 },
    });

    _ = try mod.addInst(func_id, b3, .{
        .op = .ret,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .none = {} },
    });

    return mod;
}

fn buildDiamondModule(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);

    const func_id = try mod.addFunction("diamond", try mod.types.voidType(), .internal);
    const b0 = try mod.addBlock(func_id, "entry");
    const b1 = try mod.addBlock(func_id, "left");
    const b2 = try mod.addBlock(func_id, "right");
    const b3 = try mod.addBlock(func_id, "exit");

    const c1 = try mod.addInst(func_id, b0, .{
        .op = .@"const",
        .ty = try mod.types.scalarType(.i1),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .const_data = .{ .bool = true } },
    });
    _ = try mod.addInst(func_id, b0, .{
        .op = .cond_br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .cond_branch = .{ .cond = c1, .then_block = b1, .else_block = b2 } },
    });

    _ = try mod.addInst(func_id, b1, .{
        .op = .br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .block_target = b3 },
    });

    _ = try mod.addInst(func_id, b2, .{
        .op = .br,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .block_target = b3 },
    });

    _ = try mod.addInst(func_id, b3, .{
        .op = .ret,
        .ty = try mod.types.voidType(),
        .result = bir.NO_VALUE,
        .operands = &.{},
        .data = .{ .none = {} },
    });

    return mod;
}

// ─── Tests ───

fn testLinearCFG(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testLinearCFG ---\n");
    var mod = try buildSimpleAddModule(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var cfg = try bir_cfg.buildCFG(alloc, func);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.blocks.items.len);
    try std.testing.expectEqual(@as(bir.BlockId, 0), cfg.entry);

    try bir_cfg.dumpCFG(&cfg, stdout);

    try stdout.print("  OK\n", .{});
}

fn testIfElseCFG(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testIfElseCFG ---\n");
    var mod = try buildIfElseModule(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var cfg = try bir_cfg.buildCFG(alloc, func);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 4), cfg.blocks.items.len);

    const b0_succs = cfg.get(0).successors.items;
    try std.testing.expectEqual(@as(usize, 2), b0_succs.len);
    try std.testing.expectEqual(@as(bir.BlockId, 1), b0_succs[0]);
    try std.testing.expectEqual(@as(bir.BlockId, 2), b0_succs[1]);

    const b3_preds = cfg.get(3).predecessors.items;
    try std.testing.expectEqual(@as(usize, 2), b3_preds.len);

    try bir_cfg.dumpCFG(&cfg, stdout);

    try stdout.print("  OK\n", .{});
}

fn testLoopCFG(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testLoopCFG ---\n");
    var mod = try buildLoopModule(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var cfg = try bir_cfg.buildCFG(alloc, func);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 4), cfg.blocks.items.len);
    try std.testing.expect(bir_cfg.isBackEdge(&cfg, 2, 1));

    var dom_tree = try bir_dominators.buildDominators(alloc, &cfg);
    defer dom_tree.deinit();

    try dom_tree.dump(stdout, 4);

    try std.testing.expect(dom_tree.dominates(0, 1));
    try std.testing.expect(dom_tree.dominates(0, 2));
    try std.testing.expect(dom_tree.dominates(0, 3));
    try std.testing.expect(dom_tree.dominates(1, 2));

    const loops = try bir_loops.findLoops(alloc, &cfg, &dom_tree);
    defer {
        for (loops) |*lp| {
            alloc.free(lp.back_edges);
            alloc.free(lp.body);
        }
        alloc.free(loops);
    }

    try bir_loops.dumpLoops(loops, stdout);
    try std.testing.expect(loops.len > 0);

    try stdout.print("  OK\n", .{});
}

fn testDominators(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testDominators ---\n");
    var mod = try buildDiamondModule(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var cfg = try bir_cfg.buildCFG(alloc, func);
    defer cfg.deinit();

    var dom_tree = try bir_dominators.buildDominators(alloc, &cfg);
    defer dom_tree.deinit();

    try dom_tree.dump(stdout, 4);

    try std.testing.expectEqual(bir.INVALID_ID, dom_tree.getImmediateDominator(0));
    try std.testing.expectEqual(@as(bir.BlockId, 0), dom_tree.getImmediateDominator(1));
    try std.testing.expectEqual(@as(bir.BlockId, 0), dom_tree.getImmediateDominator(2));
    try std.testing.expectEqual(@as(bir.BlockId, 0), dom_tree.getImmediateDominator(3));

    try std.testing.expect(dom_tree.dominates(0, 1));
    try std.testing.expect(dom_tree.dominates(0, 2));
    try std.testing.expect(dom_tree.dominates(0, 3));
    try std.testing.expect(!dom_tree.dominates(1, 2));
    try std.testing.expect(!dom_tree.dominates(2, 1));
    try std.testing.expect(dom_tree.strictlyDominates(0, 3));
    try std.testing.expect(!dom_tree.strictlyDominates(3, 3));

    try stdout.print("  OK\n", .{});
}

fn testDominanceFrontiers(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testDominanceFrontiers ---\n");
    var mod = try buildDiamondModule(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var cfg = try bir_cfg.buildCFG(alloc, func);
    defer cfg.deinit();

    var dom_tree = try bir_dominators.buildDominators(alloc, &cfg);
    defer dom_tree.deinit();

    var df = try bir_dominators.buildDominanceFrontiers(alloc, &cfg, &dom_tree);
    defer df.deinit();

    try df.dump(stdout);

    try std.testing.expectEqual(@as(usize, 0), df.get(0).len);
    try std.testing.expectEqual(@as(usize, 1), df.get(1).len);
    try std.testing.expectEqual(@as(usize, 1), df.get(2).len);
    try std.testing.expectEqual(@as(usize, 0), df.get(3).len);
    try std.testing.expect(df.contains(1, 3));
    try std.testing.expect(df.contains(2, 3));

    try stdout.print("  OK\n", .{});
}

fn testCFGValidation(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCFGValidation ---\n");
    var mod = try buildIfElseModule(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var cfg = try bir_cfg.buildCFG(alloc, func);
    defer cfg.deinit();

    const result = bir_cfg.validate(&cfg, func);
    if (result) {
        try stdout.print("  Validation: OK\n", .{});
    } else |err| {
        try stdout.print("  Validation error: {s}\n", .{@errorName(err)});
        return error.TestFailed;
    }

    try stdout.print("  OK\n", .{});
}

fn testConstantFolding(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testConstantFolding ---\n");
    var mod = try buildSimpleAddModule(alloc);
    defer mod.deinit();

    var pm = bir_passes.ConstantFoldingPass;
    _ = try pm.run(&mod, alloc);

    const func = mod.getFunction(0);
    const block = &func.blocks.items[0];

    var found_const30 = false;
    for (block.instrs.items) |inst| {
        if (inst.op == .@"const") {
            if (inst.data.const_data == .int) {
                if (inst.data.const_data.int == 30) {
                    found_const30 = true;
                }
            }
        }
    }

    try std.testing.expect(found_const30);
    try stdout.print("  Found const 30 after folding 10+20: PASS\n", .{});

    try stdout.print("  OK\n", .{});
}

fn testDCE(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testDCE ---\n");
    var mod = try buildSimpleAddModule(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    const instrs_before = func.blocks.items[0].instrs.items.len;

    var pm = bir_passes.DCEPass;
    _ = try pm.run(&mod, alloc);

    const instrs_after = func.blocks.items[0].instrs.items.len;
    try stdout.print("  instrs before: {d}, after: {d}\n", .{ instrs_before, instrs_after });
    try std.testing.expect(instrs_after <= instrs_before);

    try stdout.print("  OK\n", .{});
}

fn testFullPipeline(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testFullPipeline ---\n");
    var mod = try buildIfElseModule(alloc);
    defer mod.deinit();

    var pm = bir_passes.StandardPasses.init(alloc);
    defer pm.deinit();
    try pm.run(&mod);

    const func = mod.getFunction(0);
    try stdout.print("  blocks: {d}, values: {d}\n", .{ func.blocks.items.len, func.locals_count });

    try stdout.print("  OK\n", .{});
}

fn testMem2Reg(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testMem2Reg ---\n");

    // Test 1: Simple alloca → store → load in linear CFG
    {
        try stdout.writeAll("  test 1: linear alloca\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const i64_ty = try mod.types.scalarType(.i64);
        const func_id = try mod.addFunction("linear", try mod.types.voidType(), .internal);
        const b0 = try mod.addBlock(func_id, "entry");
        const b1 = try mod.addBlock(func_id, "exit");

        const alloca_val = try mod.addInst(func_id, b0, .{
            .op = .alloca, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .none = {} },
        });
        const c42 = try mod.addInst(func_id, b0, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 42 } },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c42 }),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b1 },
        });

        const loaded = try mod.addInst(func_id, b1, .{
            .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b1, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{loaded}),
            .data = .{ .none = {} },
        });

        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_mem2reg.Mem2RegPass);
        try pm.run(&mod);

        const func = mod.getFunction(func_id);
        var found_alloca = false;
        var found_store = false;
        var found_load = false;
        var ret_operand: bir.ValueId = bir.NO_VALUE;
        for (func.blocks.items) |blk| {
            for (blk.instrs.items) |inst| {
                if (inst.op == .alloca) found_alloca = true;
                if (inst.op == .store) found_store = true;
                if (inst.op == .load) found_load = true;
                if (inst.op == .ret and inst.operands.len > 0) ret_operand = inst.operands[0];
            }
        }
        try stdout.print("    alloca={}, store={}, load={}, ret_operand={d}\n", .{ found_alloca, found_store, found_load, ret_operand });
        try std.testing.expect(!found_alloca);
        try std.testing.expect(!found_store);
        try std.testing.expect(!found_load);

        try std.testing.expect(ret_operand == c42);
        try stdout.print("    PASS: ret uses const 42 directly\n", .{});
    }

    // Test 2: Diamond CFG — alloca in both branches, loads in merge
    {
        try stdout.writeAll("  test 2: diamond alloca (phi insertion)\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const i64_ty = try mod.types.scalarType(.i64);
        const i1_ty = try mod.types.scalarType(.i1);
        const func_id = try mod.addFunction("diamond", try mod.types.voidType(), .internal);
        const b0 = try mod.addBlock(func_id, "entry");
        const b1 = try mod.addBlock(func_id, "if.then");
        const b2 = try mod.addBlock(func_id, "if.else");
        const b3 = try mod.addBlock(func_id, "if.merge");

        const cond = try mod.addInst(func_id, b0, .{
            .op = .@"const", .ty = i1_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .bool = true } },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{},
            .data = .{ .cond_branch = .{ .cond = cond, .then_block = b1, .else_block = b2 } },
        });

        const alloca_val = try mod.addInst(func_id, b1, .{
            .op = .alloca, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .none = {} },
        });
        const c10 = try mod.addInst(func_id, b1, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
        });
        _ = try mod.addInst(func_id, b1, .{
            .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c10 }),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b1, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b3 },
        });

        _ = try mod.addInst(func_id, b2, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b3 },
        });

        const loaded = try mod.addInst(func_id, b3, .{
            .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b3, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{loaded}),
            .data = .{ .none = {} },
        });

        try stdout.writeAll("    before:\n");
        {
            const func_b = mod.getFunction(func_id);
            for (func_b.blocks.items, 0..) |blk, bi| {
                try stdout.print("      block {d} '{s}':\n", .{ bi, blk.label });
                for (blk.instrs.items) |inst| {
                    try stdout.print("        [{d}] {s} ops=[", .{ inst.result, @tagName(inst.op) });
                    for (inst.operands, 0..) |op, oi| {
                        if (oi > 0) try stdout.writeAll(", ");
                        try stdout.print("{d}", .{op});
                    }
                    try stdout.writeAll("]\n");
                }
            }
        }

        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_mem2reg.Mem2RegPass);
        try pm.run(&mod);

        try stdout.writeAll("    after:\n");
        var found_phi = false;
        var found_alloca = false;
        var found_store = false;
        var found_load = false;
        {
            const func_a = mod.getFunction(func_id);
            for (func_a.blocks.items, 0..) |blk, bi| {
                try stdout.print("      block {d} '{s}':\n", .{ bi, blk.label });
                for (blk.instrs.items) |inst| {
                    if (inst.op == .phi) found_phi = true;
                    if (inst.op == .alloca) found_alloca = true;
                    if (inst.op == .store) found_store = true;
                    if (inst.op == .load) found_load = true;
                    try stdout.print("        [{d}] {s} ops=[", .{ inst.result, @tagName(inst.op) });
                    for (inst.operands, 0..) |op, oi| {
                        if (oi > 0) try stdout.writeAll(", ");
                        try stdout.print("{d}", .{op});
                    }
                    try stdout.writeAll("]\n");
                }
            }
        }

        try std.testing.expect(!found_alloca);
        try std.testing.expect(!found_store);
        try std.testing.expect(!found_load);

        try stdout.print("    phi_inserted={}\n", .{found_phi});
        try stdout.print("    PASS\n", .{});
    }

    // Test 3: Store dominant — same value stored in all paths
    {
        try stdout.writeAll("  test 3: store dominant\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const i64_ty = try mod.types.scalarType(.i64);
        const func_id = try mod.addFunction("dominant", try mod.types.voidType(), .internal);
        const b0 = try mod.addBlock(func_id, "entry");

        const alloca_val = try mod.addInst(func_id, b0, .{
            .op = .alloca, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .none = {} },
        });
        const c99 = try mod.addInst(func_id, b0, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 99 } },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c99 }),
            .data = .{ .none = {} },
        });
        const loaded = try mod.addInst(func_id, b0, .{
            .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{loaded}),
            .data = .{ .none = {} },
        });

        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_mem2reg.Mem2RegPass);
        try pm.run(&mod);

        const func = mod.getFunction(func_id);
        var found_alloca = false;
        var found_store = false;
        var found_load = false;
        var ret_operand: bir.ValueId = bir.NO_VALUE;
        for (func.blocks.items) |blk| {
            for (blk.instrs.items) |inst| {
                if (inst.op == .alloca) found_alloca = true;
                if (inst.op == .store) found_store = true;
                if (inst.op == .load) found_load = true;
                if (inst.op == .ret and inst.operands.len > 0) ret_operand = inst.operands[0];
            }
        }
        try std.testing.expect(!found_alloca);
        try std.testing.expect(!found_store);
        try std.testing.expect(!found_load);
        try std.testing.expect(ret_operand == c99);
        try stdout.print("    PASS: ret_operand = const 99\n", .{});
    }

    // Test 4: if/else phi — stores in BOTH branches, phi inserted at merge
    // Expected after mem2reg:
    //   entry:  const 10, const 20, cond_br → then/else
    //   then:   br merge
    //   else:   br merge
    //   merge:  phi [10, then], [20, else] → ret phi_result
    {
        try stdout.writeAll("  test 4: if/else diamond phi\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const i64_ty = try mod.types.scalarType(.i64);
        const func_id = try mod.addFunction("if_else_phi", try mod.types.voidType(), .internal);

        const b_entry = try mod.addBlock(func_id, "entry");
        const b_then = try mod.addBlock(func_id, "if.then");
        const b_else = try mod.addBlock(func_id, "if.else");
        const b_merge = try mod.addBlock(func_id, "if.merge");

        // entry: alloca, const 10, const 20, store 10, store 20, cond_br
        const alloca_val = try mod.addInst(func_id, b_entry, .{
            .op = .alloca, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .none = {} },
        });
        const c10 = try mod.addInst(func_id, b_entry, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
        });
        const c20 = try mod.addInst(func_id, b_entry, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 20 } },
        });
        // dummy condition (we don't need a real one for this test)
        const cond = try mod.addInst(func_id, b_entry, .{
            .op = .@"const", .ty = try mod.types.scalarType(.i1), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 1 } },
        });
        _ = try mod.addInst(func_id, b_entry, .{
            .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{cond}),
            .data = .{ .cond_branch = .{ .cond = cond, .then_block = b_then, .else_block = b_else } },
        });

        // then: store 10 → alloca, br merge
        _ = try mod.addInst(func_id, b_then, .{
            .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c10 }),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b_then, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b_merge },
        });

        // else: store 20 → alloca, br merge
        _ = try mod.addInst(func_id, b_else, .{
            .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c20 }),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b_else, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b_merge },
        });

        // merge: load from alloca, ret load_result
        const loaded = try mod.addInst(func_id, b_merge, .{
            .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b_merge, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{loaded}),
            .data = .{ .none = {} },
        });

        // print before
        try stdout.writeAll("    before:\n");
        {
            const func_b = mod.getFunction(func_id);
            for (func_b.blocks.items, 0..) |blk, bi| {
                try stdout.print("      block {d} '{s}':\n", .{ bi, blk.label });
                for (blk.instrs.items) |inst| {
                    try stdout.print("        [{d}] {s} ops=[", .{ inst.result, @tagName(inst.op) });
                    for (inst.operands, 0..) |op, oi| {
                        if (oi > 0) try stdout.writeAll(", ");
                        try stdout.print("{d}", .{op});
                    }
                    try stdout.writeAll("]\n");
                }
            }
        }

        // run mem2reg
        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_mem2reg.Mem2RegPass);
        try pm.run(&mod);

        // print after
        var found_phi = false;
        var phi_block: i64 = -1;
        var phi_incoming_count: usize = 0;
        var ret_operand: bir.ValueId = bir.NO_VALUE;
        try stdout.writeAll("    after:\n");
        {
            const func_a = mod.getFunction(func_id);
            for (func_a.blocks.items, 0..) |blk, bi| {
                try stdout.print("      block {d} '{s}':\n", .{ bi, blk.label });
                for (blk.instrs.items) |inst| {
                    if (inst.op == .phi) {
                        found_phi = true;
                        phi_block = @intCast(bi);
                        phi_incoming_count = inst.data.phi_incoming.len;
                        // print phi incoming
                        try stdout.print("        [{d}] phi incoming=[", .{inst.result});
                        for (inst.data.phi_incoming, 0..) |inc, ii| {
                            if (ii > 0) try stdout.writeAll(", ");
                            try stdout.print("({d}, blk{d})", .{ inc.value, inc.block });
                        }
                        try stdout.writeAll("]\n");
                    } else {
                        if (inst.op == .ret and inst.operands.len > 0) ret_operand = inst.operands[0];
                        try stdout.print("        [{d}] {s} ops=[", .{ inst.result, @tagName(inst.op) });
                        for (inst.operands, 0..) |op, oi| {
                            if (oi > 0) try stdout.writeAll(", ");
                            try stdout.print("{d}", .{op});
                        }
                        try stdout.writeAll("]\n");
                    }
                }
            }
        }

        // verify: alloca/store/load gone
        var found_alloca = false;
        var found_store = false;
        var found_load = false;
        {
            const func_v = mod.getFunction(func_id);
            for (func_v.blocks.items) |blk| {
                for (blk.instrs.items) |inst| {
                    if (inst.op == .alloca) found_alloca = true;
                    if (inst.op == .store) found_store = true;
                    if (inst.op == .load) found_load = true;
                }
            }
        }
        try std.testing.expect(!found_alloca);
        try std.testing.expect(!found_store);
        try std.testing.expect(!found_load);

        // verify: phi exists in merge block
        try std.testing.expect(found_phi);
        try std.testing.expectEqual(@as(i64, 3), phi_block); // merge is block 3
        try std.testing.expectEqual(@as(usize, 2), phi_incoming_count);

        // verify: ret operand is phi result
        const func_check = mod.getFunction(func_id);
        const merge_blk = func_check.blocks.items[3];
        for (merge_blk.instrs.items) |inst| {
            if (inst.op == .phi) {
                try std.testing.expectEqual(inst.result, ret_operand);
            }
        }

        // verify: phi incoming values are the constants (c10, c20)
        for (merge_blk.instrs.items) |inst| {
            if (inst.op == .phi) {
                const inc0 = inst.data.phi_incoming[0];
                const inc1 = inst.data.phi_incoming[1];
                // values should be c10 and c20 (order may vary)
                const v0 = if (inc0.value == c10) @as(i64, 10) else if (inc0.value == c20) @as(i64, 20) else -1;
                const v1 = if (inc1.value == c10) @as(i64, 10) else if (inc1.value == c20) @as(i64, 20) else -1;
                try std.testing.expect(v0 == 10 or v0 == 20);
                try std.testing.expect(v1 == 10 or v1 == 20);
                try std.testing.expect(v0 + v1 == 30); // one is 10, other is 20

                // verify incoming blocks are then and else
                const b0 = inc0.block;
                const b1 = inc1.block;
                try std.testing.expect((b0 == b_then and b1 == b_else) or (b0 == b_else and b1 == b_then));

                try stdout.print("    phi: [{d},blk{d}] [{d},blk{d}]\n", .{ inc0.value, inc0.block, inc1.value, inc1.block });
            }
        }

        // verify with verifier
        {
            const func_v = mod.getFunctionMut(func_id);
            bir_verify.verifyFunction(&mod, func_v, func_id, alloc) catch |e| {
                try stdout.print("    VERIFIER FAILED: {}\n", .{e});
                return error.TestFailed;
            };
            try stdout.print("    verifier: OK\n", .{});
        }

        try stdout.print("    PASS\n", .{});
    }

    // Test 5: mem2reg + cfgsimplify pipeline
    {
        try stdout.writeAll("  test 5: mem2reg + cfgsimplify pipeline\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const i64_ty = try mod.types.scalarType(.i64);
        const func_id = try mod.addFunction("pipe_test", try mod.types.voidType(), .internal);

        // entry → middle → exit
        // entry: alloca, store 42, br → middle
        // middle: load alloca, store 42 again, br → exit
        // exit: load alloca, ret
        const b_entry = try mod.addBlock(func_id, "entry");
        const b_middle = try mod.addBlock(func_id, "middle");
        const b_exit = try mod.addBlock(func_id, "exit");

        const alloca_val = try mod.addInst(func_id, b_entry, .{
            .op = .alloca, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .none = {} },
        });
        const c42 = try mod.addInst(func_id, b_entry, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 42 } },
        });
        _ = try mod.addInst(func_id, b_entry, .{
            .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c42 }),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b_entry, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b_middle },
        });

        // middle: load (dead), store again, br exit
        _ = try mod.addInst(func_id, b_middle, .{
            .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
            .data = .{ .none = {} },
        });
        const c42b = try mod.addInst(func_id, b_middle, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 42 } },
        });
        _ = try mod.addInst(func_id, b_middle, .{
            .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c42b }),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b_middle, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b_exit },
        });

        // exit: load, ret
        const final_load = try mod.addInst(func_id, b_exit, .{
            .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
            .data = .{ .none = {} },
        });
        _ = try mod.addInst(func_id, b_exit, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{final_load}),
            .data = .{ .none = {} },
        });

        // run pipeline: mem2reg then cfgsimplify
        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_mem2reg.Mem2RegPass);
        try pm.addPass(bir_cfgsimplify.CFGSimplifyPass);
        try pm.run(&mod);

        // verify: no alloca/store/load
        var found_alloca = false;
        var found_store = false;
        var found_load = false;
        var nblocks: usize = 0;
        {
            const func_p = mod.getFunction(func_id);
            nblocks = func_p.blocks.items.len;
            for (func_p.blocks.items) |blk| {
                for (blk.instrs.items) |inst| {
                    if (inst.op == .alloca) found_alloca = true;
                    if (inst.op == .store) found_store = true;
                    if (inst.op == .load) found_load = true;
                }
            }
        }
        try std.testing.expect(!found_alloca);
        try std.testing.expect(!found_store);
        try std.testing.expect(!found_load);

        const func_check = mod.getFunctionMut(func_id);
        var ret_is_const42 = false;
        for (func_check.blocks.items) |blk| {
            for (blk.instrs.items) |inst| {
                if (inst.op == .ret and inst.operands.len > 0) {
                    const vi = func_check.getValueInfo(inst.operands[0]);
                    if (vi.def.block < func_check.blocks.items.len) {
                        const def_block = func_check.blocks.items[vi.def.block];
                        if (vi.def.idx < def_block.instrs.items.len) {
                            const def_inst = def_block.instrs.items[vi.def.idx];
                            if (def_inst.op == .@"const" and def_inst.data.const_data.int == 42) {
                                ret_is_const42 = true;
                            }
                        }
                    }
                }
            }
        }
        try std.testing.expect(ret_is_const42);

        try stdout.print("    blocks: {d}, ret = const 42\n", .{nblocks});
        try stdout.print("    PASS\n", .{});
    }

    try stdout.print("  ALL mem2reg tests PASSED\n", .{});
}

// ─── CFGSimplify dedicated tests ───

fn testCFGSimplify(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("\n--- testCFGSimplify ---\n");

    {
        try stdout.writeAll("  test 1: straight-line merge\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const i64_ty = try mod.types.scalarType(.i64);
        const func_id = try mod.addFunction("merge_test", try mod.types.voidType(), .internal);

        const b0 = try mod.addBlock(func_id, "entry");
        const b1 = try mod.addBlock(func_id, "middle");
        const b2 = try mod.addBlock(func_id, "exit");

        _ = try mod.addInst(func_id, b0, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 5 } },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b1 },
        });

        _ = try mod.addInst(func_id, b1, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
        });
        _ = try mod.addInst(func_id, b1, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b2 },
        });

        const c_exit = try mod.addInst(func_id, b2, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 99 } },
        });
        _ = try mod.addInst(func_id, b2, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{c_exit}),
            .data = .{ .none = {} },
        });

        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_cfgsimplify.CFGSimplifyPass);
        try pm.run(&mod);

        var nblocks: usize = 0;
        {
            const f = mod.getFunction(func_id);
            nblocks = f.blocks.items.len;
            try stdout.print("    blocks: {d}\n", .{nblocks});
            for (f.blocks.items, 0..) |blk, bi| {
                try stdout.print("      block {d} '{s}':", .{ bi, blk.label });
                for (blk.instrs.items) |inst| {
                    try stdout.print(" {s}", .{@tagName(inst.op)});
                }
                try stdout.writeAll("\n");
            }
            const b0_block = f.blocks.items[0];
            const term = b0_block.instrs.items[b0_block.instrs.items.len - 1];
            try stdout.print("    last op in b0: {s}\n", .{@tagName(term.op)});
            try std.testing.expect(term.op == .ret);
            try std.testing.expectEqual(@as(usize, 4), b0_block.instrs.items.len);
        }
        try std.testing.expect(nblocks == 3);
        try stdout.print("    PASS\n", .{});
    }

    {
        try stdout.writeAll("  test 2: redirect chain\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const func_id = try mod.addFunction("redirect_chain", try mod.types.voidType(), .internal);
        const b0 = try mod.addBlock(func_id, "start");
        const b1 = try mod.addBlock(func_id, "skip_me");
        const b2 = try mod.addBlock(func_id, "end");

        _ = try mod.addInst(func_id, b0, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b1 },
        });
        _ = try mod.addInst(func_id, b1, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b2 },
        });
        _ = try mod.addInst(func_id, b2, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .none = {} },
        });

        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_cfgsimplify.CFGSimplifyPass);
        try pm.run(&mod);

        {
            const f = mod.getFunction(func_id);
            const start_term = f.blocks.items[0].instrs.items[0];
            try std.testing.expect(start_term.op == .ret);
        }
        try stdout.writeAll("    PASS\n");
    }

    {
        try stdout.writeAll("  test 3: cond_br redirect both targets\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const func_id = try mod.addFunction("cond_redirect", try mod.types.voidType(), .internal);
        const b0 = try mod.addBlock(func_id, "entry");
        const b1 = try mod.addBlock(func_id, "then_skip");
        const b2 = try mod.addBlock(func_id, "else_skip");
        const b3 = try mod.addBlock(func_id, "merge");

        const cond = try mod.addInst(func_id, b0, .{
            .op = .@"const", .ty = try mod.types.scalarType(.i1), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 1 } },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{cond}),
            .data = .{ .cond_branch = .{ .cond = cond, .then_block = b1, .else_block = b2 } },
        });
        _ = try mod.addInst(func_id, b1, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b3 },
        });
        _ = try mod.addInst(func_id, b2, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b3 },
        });
        _ = try mod.addInst(func_id, b3, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .none = {} },
        });

        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_cfgsimplify.CFGSimplifyPass);
        try pm.run(&mod);

        {
            const f = mod.getFunction(func_id);
            const entry_term = f.blocks.items[0].instrs.items[f.blocks.items[0].instrs.items.len - 1];
            try std.testing.expect(entry_term.op == .cond_br);
            try std.testing.expect(entry_term.data.cond_branch.then_block == b3);
            try std.testing.expect(entry_term.data.cond_branch.else_block == b3);
        }
        try stdout.writeAll("    PASS\n");
    }

    {
        try stdout.writeAll("  test 4: replaceAllUses after merge\n");
        var mod = bir.Module.init(alloc);
        defer mod.deinit();

        const i64_ty = try mod.types.scalarType(.i64);
        const func_id = try mod.addFunction("use_replace", try mod.types.voidType(), .internal);

        const b0 = try mod.addBlock(func_id, "entry");
        const b1 = try mod.addBlock(func_id, "middle");
        const b2 = try mod.addBlock(func_id, "exit");

        _ = try mod.addInst(func_id, b0, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 5 } },
        });
        _ = try mod.addInst(func_id, b0, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b1 },
        });

        const c10_in_b1 = try mod.addInst(func_id, b1, .{
            .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
        });
        _ = try mod.addInst(func_id, b1, .{
            .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = b2 },
        });

        _ = try mod.addInst(func_id, b2, .{
            .op = .ret, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
            .operands = try alloc.dupe(bir.ValueId, &.{c10_in_b1}),
            .data = .{ .none = {} },
        });

        var pm = bir.PassManager.init(alloc);
        defer pm.deinit();
        try pm.addPass(bir_cfgsimplify.CFGSimplifyPass);
        try pm.run(&mod);

        {
            const f = mod.getFunctionMut(func_id);
            const b0_block = f.blocks.items[0];
            var found_const10 = false;
            for (b0_block.instrs.items) |inst| {
                if (inst.op == .@"const" and inst.data.const_data.int == 10) found_const10 = true;
                if (inst.op == .ret) {
                    try std.testing.expect(inst.operands.len > 0);
                    const ret_val = inst.operands[0];
                    const vi = f.getValueInfo(ret_val);
                    try std.testing.expectEqual(@as(bir.BlockId, 0), vi.def.block);
                }
            }
            try std.testing.expect(found_const10);
        }
        try stdout.writeAll("    PASS\n");
    }

    try stdout.print("  ALL cfgsimplify tests PASSED\n", .{});
}
