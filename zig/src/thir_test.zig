const std = @import("std");
const testing = std.testing;
const thir_mod = @import("compiler/middle/thir/thir.zig");
const verify_mod = @import("compiler/middle/thir/verify.zig");
const dump_mod = @import("compiler/middle/thir/dump.zig");
const cfg_mod = @import("compiler/middle/thir/analysis/cfg.zig");
const dom_mod = @import("compiler/middle/thir/analysis/dominance.zig");
const reach_mod = @import("compiler/middle/thir/analysis/reachability.zig");
const loops_mod = @import("compiler/middle/thir/analysis/loops.zig");

const ThirModule = thir_mod.ThirModule;
const ThirFunction = thir_mod.ThirFunction;
const BasicBlock = thir_mod.BasicBlock;
const ThirStmt = thir_mod.ThirStmt;
const ThirExpr = thir_mod.ThirExpr;
const ValueId = thir_mod.ValueId;
const BlockId = thir_mod.BlockId;
const INVALID_BLOCK = thir_mod.INVALID_BLOCK;

// ═══════════════════════════════════════════════════
// Core IR tests
// ═══════════════════════════════════════════════════

test "ThirModule init/deinit" {
    var module = ThirModule.init(testing.allocator);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.functions.items.len);
    try testing.expectEqual(@as(usize, 0), module.structs.items.len);
}

test "ThirModule addFunction" {
    var module = ThirModule.init(testing.allocator);
    defer module.deinit();

    const idx = try module.addFunction(.{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = null,
        .linkage = .internal,
    });

    try testing.expectEqual(@as(u32, 0), idx);
    try testing.expectEqual(@as(usize, 1), module.functions.items.len);
}

test "ValueId typed id semantics" {
    const v1 = ValueId.new(0);
    const v2 = ValueId.new(1);
    const v3 = ValueId.new(0);

    try testing.expect(v1.eql(v3));
    try testing.expect(!v1.eql(v2));
    try testing.expect(v1.isValid());
    try testing.expect(!ValueId.INVALID.isValid());
}

test "BlockId typed id semantics" {
    const b1 = BlockId.new(5);
    const b2 = BlockId.new(5);
    const b3 = BlockId.new(6);

    try testing.expect(b1.eql(b2));
    try testing.expect(!b1.eql(b3));
    try testing.expect(b1.isValid());
    try testing.expect(!BlockId.INVALID.isValid());
}

test "BinOp enum has 18 operations" {
    const ops = [_]thir_mod.BinOp{
        .add, .sub, .mul, .div, .mod,
        .eq, .ne, .lt, .le, .gt, .ge,
        .and_, .or_,
        .bitwise_and, .bitwise_or, .bitwise_xor, .shl, .shr,
    };
    try testing.expectEqual(@as(usize, 18), ops.len);
}

test "UnOp enum has 3 operations" {
    const ops = [_]thir_mod.UnOp{ .negate, .not, .bitwise_not };
    try testing.expectEqual(@as(usize, 3), ops.len);
}

test "CastKind has 16 conversion types" {
    const kinds = [_]thir_mod.CastKind{
        .int_extend_signed, .int_extend_unsigned, .int_truncate,
        .int_to_float, .uint_to_float, .float_to_int, .float_to_uint,
        .float_extend, .float_truncate,
        .bool_to_int, .int_to_bool,
        .pointer_cast, .pointer_to_int, .int_to_pointer,
        .bitcast, .unsize,
    };
    try testing.expectEqual(@as(usize, 16), kinds.len);
}

test "Place with projections" {
    const proj = [_]thir_mod.Place.Projection{
        .{ .field = 0 },
        .{ .deref = {} },
        .{ .field = 2 },
    };
    const place = thir_mod.Place{
        .local = ValueId.new(5),
        .projections = &proj,
    };
    try testing.expectEqual(ValueId.new(5), place.local);
    try testing.expectEqual(@as(usize, 3), place.projections.len);
}

test "Literal types" {
    const lits = [_]thir_mod.Literal{
        .{ .int = 42 },
        .{ .float = 3.14 },
        .{ .bool_val = true },
        .{ .string = .{ .index = 0 } },
        .{ .unit = {} },
    };
    try testing.expectEqual(@as(usize, 5), lits.len);
}

test "ThirFunction linkage types" {
    const linkages = [_]ThirFunction.Linkage{ .@"export", .internal, .entry };
    try testing.expectEqual(@as(usize, 3), linkages.len);
}

// ═══════════════════════════════════════════════════
// Verifier tests
// ═══════════════════════════════════════════════════

test "VerifyContext: valid module passes" {
    var module = ThirModule.init(testing.allocator);
    defer module.deinit();

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    _ = try module.addFunction(.{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &.{}, .exprs = &.{}, .places = &.{} },
        .linkage = .internal,
    });

    var ctx = verify_mod.VerifyContext.init(testing.allocator, &module);
    defer ctx.deinit();

    const ok = try ctx.verify();
    try testing.expect(ok);
}

test "VerifyContext: invalid block reference fails" {
    var module = ThirModule.init(testing.allocator);
    defer module.deinit();

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(99) } },
    };

    _ = try module.addFunction(.{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &.{}, .exprs = &.{}, .places = &.{} },
        .linkage = .internal,
    });

    var ctx = verify_mod.VerifyContext.init(testing.allocator, &module);
    defer ctx.deinit();

    const ok = try ctx.verify();
    try testing.expect(!ok);
    try testing.expect(ctx.errors.items.len > 0);
}

// ═══════════════════════════════════════════════════
// CFG tests
// ═══════════════════════════════════════════════════

fn makeFunc(blocks: []const BasicBlock, entry: BlockId) ThirFunction {
    return .{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = .{ .blocks = blocks, .entry = entry, .values = &.{}, .exprs = &.{}, .places = &.{} },
        .linkage = .internal,
    };
}

test "CFG: empty function" {
    var func = makeFunc(&.{}, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();
    try testing.expectEqual(@as(u32, 0), cfg.block_count);
}

test "CFG: linear entry -> exit" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "exit", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    try testing.expectEqual(@as(u32, 2), cfg.block_count);
    try testing.expectEqual(@as(usize, 2), cfg.reverse_post_order.len);
    // idom[entry] = entry
    try testing.expectEqual(BlockId.new(0), cfg.idom[0]);
}

test "CFG: diamond if-merge" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    try testing.expectEqual(@as(u32, 4), cfg.block_count);

    // idom[then] = entry, idom[else] = entry, idom[merge] = entry
    try testing.expectEqual(BlockId.new(0), cfg.idom[1]);
    try testing.expectEqual(BlockId.new(0), cfg.idom[2]);
    try testing.expectEqual(BlockId.new(0), cfg.idom[3]);

    // entry dominates all
    try testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(1)));
    try testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(2)));
    try testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(3)));
}

test "CFG: loop header dominates body" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "header", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(2), .else_ = BlockId.new(3) } } },
        .{ .label = "body", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "exit", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    try testing.expect(cfg.dominates(BlockId.new(1), BlockId.new(2)));
    try testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(1)));
    try testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(2)));
}

test "CFG: unreachable block not in RPO" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
        .{ .label = "dead", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.reverse_post_order.len);
    try testing.expect(cfg.isReachable(BlockId.new(0)));
    try testing.expect(!cfg.isReachable(BlockId.new(1)));
}

test "CFG: edges have correct kinds" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 4), cfg.edges.len);
    try testing.expectEqual(cfg_mod.EdgeKind.true_branch, cfg.edges[0].kind);
    try testing.expectEqual(cfg_mod.EdgeKind.false_branch, cfg.edges[1].kind);
    try testing.expectEqual(cfg_mod.EdgeKind.normal, cfg.edges[2].kind);
    try testing.expectEqual(cfg_mod.EdgeKind.normal, cfg.edges[3].kind);
}

// ═══════════════════════════════════════════════════
// Dominance tests
// ═══════════════════════════════════════════════════

test "DominanceTree: same block" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var tree = try dom_mod.buildDominatorTree(testing.allocator, &func);
    defer tree.deinit();
    try testing.expect(tree.dominates(BlockId.new(0), BlockId.new(0)));
}

test "DominanceTree: linear chain" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "b1", .stmts = &.{}, .terminator = .{ .br = BlockId.new(2) } },
        .{ .label = "b2", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var tree = try dom_mod.buildDominatorTree(testing.allocator, &func);
    defer tree.deinit();

    try testing.expect(tree.dominates(BlockId.new(0), BlockId.new(1)));
    try testing.expect(tree.dominates(BlockId.new(0), BlockId.new(2)));
    try testing.expect(tree.dominates(BlockId.new(1), BlockId.new(2)));
    try testing.expect(!tree.dominates(BlockId.new(2), BlockId.new(1)));
}

test "DominanceTree: diamond merge not dominated by then/else" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var tree = try dom_mod.buildDominatorTree(testing.allocator, &func);
    defer tree.deinit();

    try testing.expect(tree.dominates(BlockId.new(0), BlockId.new(3)));
    try testing.expect(!tree.dominates(BlockId.new(1), BlockId.new(3)));
    try testing.expect(!tree.dominates(BlockId.new(2), BlockId.new(3)));
}

test "DominanceTree: idom values in diamond" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var tree = try dom_mod.buildDominatorTree(testing.allocator, &func);
    defer tree.deinit();

    try testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(0)));
    try testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(1)));
    try testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(2)));
    try testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(3)));
}

// ═══════════════════════════════════════════════════
// Reachability tests
// ═══════════════════════════════════════════════════

test "Reachability: all reachable in linear" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "b1", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var reach = try reach_mod.computeReachability(testing.allocator, &func);
    defer reach.deinit();

    try testing.expect(reach.isReachable(BlockId.new(0)));
    try testing.expect(reach.isReachable(BlockId.new(1)));
    try testing.expectEqual(@as(u32, 2), reach.reachableCount());
}

test "Reachability: dead block not reachable" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
        .{ .label = "dead", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var reach = try reach_mod.computeReachability(testing.allocator, &func);
    defer reach.deinit();

    try testing.expect(reach.isReachable(BlockId.new(0)));
    try testing.expect(!reach.isReachable(BlockId.new(1)));
    try testing.expectEqual(@as(u32, 1), reach.reachableCount());
}

// ═══════════════════════════════════════════════════
// Loop analysis tests
// ═══════════════════════════════════════════════════

test "LoopNest: simple loop detected" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "header", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(2), .else_ = BlockId.new(3) } } },
        .{ .label = "body", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "exit", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    var nest = try loops_mod.findNaturalLoops(testing.allocator, &cfg);
    defer nest.deinit();

    try testing.expectEqual(@as(usize, 1), nest.loops.len);
    try testing.expectEqual(BlockId.new(1), nest.loops[0].header);
}

test "LoopNest: no loop in linear CFG" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "b1", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    var nest = try loops_mod.findNaturalLoops(testing.allocator, &cfg);
    defer nest.deinit();

    try testing.expectEqual(@as(usize, 0), nest.loops.len);
}

test "LoopNest: isInnermostLoop" {
    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "header", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(2), .else_ = BlockId.new(3) } } },
        .{ .label = "body", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "exit", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunc(&blocks, BlockId.new(0));
    var cfg = try cfg_mod.buildCfg(testing.allocator, &func);
    defer cfg.deinit();

    var nest = try loops_mod.findNaturalLoops(testing.allocator, &cfg);
    defer nest.deinit();

    try testing.expect(nest.isInnermostLoop(BlockId.new(1)));
}
