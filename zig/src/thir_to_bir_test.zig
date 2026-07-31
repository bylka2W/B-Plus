const std = @import("std");
const testing = std.testing;

const thir = @import("compiler/middle/thir/thir.zig");
const thir_to_bir = @import("compiler/middle/thir/lowering/thir_to_bir.zig");
const ThirModule = thir.ThirModule;
const ThirFunction = thir.ThirFunction;
const BasicBlock = thir.BasicBlock;
const ThirExpr = thir.ThirExpr;
const ValueDef = thir.ValueDef;
const ValueId = thir.ValueId;
const ExprId = thir.ExprId;
const BlockId = thir.BlockId;
const Literal = thir.Literal;
const BinOp = thir.BinOp;

const TypeEngine = @import("compiler/frontend/type_system/type_system.zig").TypeEngine;

const bir = @import("compiler/middle/bir/bir.zig");
const BIRValueId = bir.ValueId;
const BIR_NO_VALUE = bir.NO_VALUE;

const HirTy = @import("compiler/frontend/hir/ty.zig").HirTy;
const HirItem = @import("compiler/frontend/hir/item.zig").HirItem;

var empty_types = std.ArrayList(HirTy).init(testing.allocator);
var empty_items = std.ArrayList(HirItem).init(testing.allocator);

fn makeVoidTy(engine: *TypeEngine) thir.TypeId {
    return engine.builtin(.void_type);
}

fn makeI32Ty(engine: *TypeEngine) thir.TypeId {
    return engine.builtin(.i32_type);
}

fn makeI64Ty(engine: *TypeEngine) thir.TypeId {
    return engine.builtin(.i64_type);
}

// ═══════════════════════════════════════════════════
// Test 1: Empty function
// ═══════════════════════════════════════════════════

test "THIR->BIR: empty function" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const void_ty = makeVoidTy(&engine);

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = void_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &.{}, .exprs = &.{}, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    try testing.expectEqual(@as(usize, 1), bir_mod.functions.items.len);
    const func = bir_mod.getFunctionMut(0);
    try testing.expectEqual(@as(usize, 1), func.blocks.items.len);
}

// ═══════════════════════════════════════════════════
// Test 2: Return literal
// ═══════════════════════════════════════════════════

test "THIR->BIR: return literal" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const i32_ty = makeI32Ty(&engine);

    const values = [_]ValueDef{
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(0) },
    };
    const exprs = [_]ThirExpr{
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 5 } } },
    };

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = ValueId.new(0) } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = i32_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &values, .exprs = &exprs, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    try testing.expectEqual(@as(usize, 1), bir_mod.functions.items.len);
    const func = bir_mod.getFunctionMut(0);
    try testing.expectEqual(@as(usize, 1), func.blocks.items.len);

    const entry = func.getBlock(0);
    try testing.expect(entry.instrs.items.len >= 1);

    const last = entry.instrs.items[entry.instrs.items.len - 1];
    try testing.expectEqual(bir.Op.ret, last.op);
}

// ═══════════════════════════════════════════════════
// Test 3: Binary expression (a + b)
// ═══════════════════════════════════════════════════

test "THIR->BIR: binary add" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const i32_ty = makeI32Ty(&engine);
    const void_ty = makeVoidTy(&engine);

    const values = [_]ValueDef{
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(0) },
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(1) },
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(2) },
    };
    const exprs = [_]ThirExpr{
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 10 } } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 20 } } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .binary = .{ .op = .add, .lhs = ValueId.new(0), .rhs = ValueId.new(1) } } },
    };

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = ValueId.new(2) } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = void_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &values, .exprs = &exprs, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    try testing.expectEqual(@as(usize, 1), bir_mod.functions.items.len);
    const func = bir_mod.getFunctionMut(0);

    const entry = func.getBlock(0);
    var has_add = false;
    for (entry.instrs.items) |inst| {
        if (inst.op == .add) has_add = true;
    }
    try testing.expect(has_add);

    const last = entry.instrs.items[entry.instrs.items.len - 1];
    try testing.expectEqual(bir.Op.ret, last.op);
}

// ═══════════════════════════════════════════════════
// Test 4: Let binding with store
// ═══════════════════════════════════════════════════

test "THIR->BIR: let binding creates store" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const i32_ty = makeI32Ty(&engine);

    const values = [_]ValueDef{
        .{ .ty = i32_ty, .storage = .stack, .expr = ExprId.new(0) },
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(1) },
    };
    const exprs = [_]ThirExpr{
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .none = {} } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 42 } } },
    };

    const stmts = [_]thir.ThirStmt{
        .{ .span = .{}, .kind = .{ .let = .{ .place = ValueId.new(0), .init = ValueId.new(1), .storage = .stack } } },
    };

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &stmts, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = i32_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &values, .exprs = &exprs, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    const func = bir_mod.getFunctionMut(0);
    const entry = func.getBlock(0);

    var has_store = false;
    var has_alloca = false;
    var has_const42 = false;
    for (entry.instrs.items) |inst| {
        if (inst.op == .store) has_store = true;
        if (inst.op == .alloca) has_alloca = true;
        if (inst.op == .@"const" and inst.data.const_data == .int and inst.data.const_data.int == 42) has_const42 = true;
    }
    try testing.expect(!has_alloca);
    try testing.expect(!has_store);
    try testing.expect(has_const42);
}

// ═══════════════════════════════════════════════════
// Test 5: If statement creates multiple blocks
// ═══════════════════════════════════════════════════

test "THIR->BIR: if creates cond_br" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const i32_ty = makeI32Ty(&engine);

    const values = [_]ValueDef{
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(0) },
    };
    const exprs = [_]ThirExpr{
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 1 } } },
    };

    const stmts = [_]thir.ThirStmt{
        .{ .span = .{}, .kind = .{ .if_stmt = .{ .cond = ValueId.new(0), .then_block = BlockId.new(1), .else_block = BlockId.new(2) } } },
    };

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &stmts, .terminator = .{ .diverge = {} } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(2) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = i32_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &values, .exprs = &exprs, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    const func = bir_mod.getFunctionMut(0);
    try testing.expect(func.blocks.items.len >= 2);

    const entry = func.getBlock(0);
    var has_cond_br = false;
    for (entry.instrs.items) |inst| {
        if (inst.op == .cond_br) has_cond_br = true;
    }
    try testing.expect(has_cond_br);
}

// ═══════════════════════════════════════════════════
// Test 6: Parameter function
// ═══════════════════════════════════════════════════

test "THIR->BIR: function with parameters" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const i32_ty = makeI32Ty(&engine);

    const owned_params = try allocator.alloc(ThirFunction.Param, 2);
    defer allocator.free(owned_params);
    owned_params[0] = .{ .name = .{ .index = 1 }, .def_id = .{ .index = 1 }, .ty = i32_ty, .storage = .stack };
    owned_params[1] = .{ .name = .{ .index = 2 }, .def_id = .{ .index = 2 }, .ty = i32_ty, .storage = .stack };

    const values = [_]ValueDef{
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(0) },
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(1) },
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(2) },
    };
    const exprs = [_]ThirExpr{
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 1 } } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 2 } } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .binary = .{ .op = .add, .lhs = ValueId.new(0), .rhs = ValueId.new(1) } } },
    };

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = ValueId.new(2) } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = owned_params,
        .return_type = i32_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &values, .exprs = &exprs, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    const func = bir_mod.getFunctionMut(0);
    try testing.expectEqual(@as(usize, 2), func.params.len);
    try testing.expectEqual(@as(usize, 2), func.param_values.len);

    const entry = func.getBlock(0);
    var has_add = false;
    for (entry.instrs.items) |inst| {
        if (inst.op == .add) has_add = true;
    }
    try testing.expect(has_add);
}

// ═══════════════════════════════════════════════════
// Test 7: While loop
// ═══════════════════════════════════════════════════

test "THIR->BIR: while loop creates blocks" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const i32_ty = makeI32Ty(&engine);

    const values = [_]ValueDef{
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(0) },
    };
    const exprs = [_]ThirExpr{
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 1 } } },
    };

    const stmts = [_]thir.ThirStmt{
        .{ .span = .{}, .kind = .{ .while_stmt = .{ .cond_block = BlockId.new(1), .body_block = BlockId.new(2), .exit_block = BlockId.new(3) } } },
    };

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &stmts, .terminator = .{ .diverge = {} } },
        .{ .label = "cond", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(2), .else_ = BlockId.new(3) } } },
        .{ .label = "body", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "exit", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = i32_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &values, .exprs = &exprs, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    const func = bir_mod.getFunctionMut(0);
    try testing.expect(func.blocks.items.len >= 3);
}

// ═══════════════════════════════════════════════════
// Test 8: Phi insertion at merge block
// ═══════════════════════════════════════════════════

test "THIR->BIR: phi inserted at merge block" {
    const allocator = testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    var thir_mod = ThirModule.init(allocator);
    defer thir_mod.deinit();

    const i32_ty = makeI32Ty(&engine);

    // Values: 0=cond(true), 1=literal 10, 2=literal 20, 3=x (stack)
    const values = [_]ValueDef{
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(0) },
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(1) },
        .{ .ty = i32_ty, .storage = .local_reg, .expr = ExprId.new(2) },
        .{ .ty = i32_ty, .storage = .stack, .expr = ExprId.new(3) },
    };
    const exprs = [_]ThirExpr{
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 1 } } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 10 } } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .literal = .{ .int = 20 } } },
        .{ .span = .{}, .ty = i32_ty, .kind = .{ .none = {} } },
    };

    const then_stmts = [_]thir.ThirStmt{
        .{ .span = .{}, .kind = .{ .let = .{ .place = ValueId.new(3), .init = ValueId.new(1), .storage = .stack } } },
    };
    const else_stmts = [_]thir.ThirStmt{
        .{ .span = .{}, .kind = .{ .let = .{ .place = ValueId.new(3), .init = ValueId.new(2), .storage = .stack } } },
    };

    const blocks = [_]BasicBlock{
        .{ .label = "entry", .stmts = &.{.{ .span = .{}, .kind = .{ .if_stmt = .{ .cond = ValueId.new(0), .then_block = BlockId.new(1), .else_block = BlockId.new(2) } } }}, .terminator = .{ .diverge = {} } },
        .{ .label = "then", .stmts = &then_stmts, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &else_stmts, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    _ = try thir_mod.addFunction(.{
        .name = .{ .index = 0 },
        .name_str = "test_fn",
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = i32_ty,
        .body = .{ .blocks = &blocks, .entry = BlockId.new(0), .values = &values, .exprs = &exprs, .places = &.{} },
        .linkage = .internal,
    });

    var lowerer = thir_to_bir.ThirToBir.init(allocator, &thir_mod, &empty_types, &empty_items);
    defer lowerer.deinit();
    var bir_mod = try lowerer.lower();
    defer bir_mod.deinit();

    const func = bir_mod.getFunctionMut(0);
    try testing.expect(func.blocks.items.len >= 4);

    const merge_blk = func.getBlock(3);
    var has_phi = false;
    for (merge_blk.instrs.items) |inst| {
        if (inst.op == .phi) has_phi = true;
    }
    try testing.expect(has_phi);
}
