const std = @import("std");
const backend = @import("../../src/compiler/backend/backend.zig");
const bir = backend.bir;
const bir_cpu = backend.bir_cpu;
const bir_mem2reg = backend.bir_mem2reg;
const mir = backend.mir;
const mir_x64 = backend.mir_x64;
const bir_sccp = backend.bir_sccp;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    try testSimpleRetConst(alloc, stdout);
    try testSimpleAdd(alloc, stdout);
    try testIfElse(alloc, stdout);
    try testIfElseWithPhi(alloc, stdout);
    try testNeg(alloc, stdout);
    try testNestedIfWithPhi(alloc, stdout);
    try testLoopWithPhi(alloc, stdout);
    try testCriticalEdgePhi(alloc, stdout);
    try testOptComparison(alloc, stdout);

    try stdout.print("\n=== ALL BIR→MIR E2E TESTS PASSED ===\n", .{});
}

fn executeCode(code: []const u8) i64 {
    const w = std.os.windows;
    const mem = w.VirtualAlloc(null, code.len, w.MEM_COMMIT | w.MEM_RESERVE, w.PAGE_EXECUTE_READWRITE) catch {
        @panic("VirtualAlloc failed");
    };
    defer _ = w.VirtualFree(mem, 0, w.MEM_RELEASE);
    @memcpy(@as([*]u8, @ptrCast(mem))[0..code.len], code);
    const func: *const fn () callconv(.C) i64 = @ptrCast(@alignCast(mem));
    return func();
}

fn dumpMIRInsts(writer: anytype, mfunc: *const mir.MFunction) !void {
    for (mfunc.blocks.items, 0..) |block, bi| {
        try writer.print("  b{d} '{s}':\n", .{ bi, block.label });
        for (block.instrs.items, 0..) |inst, ii| {
            try writer.print("    {d}: ", .{ii});
            switch (inst) {
                .mov => |m| {
                    try writer.print("mov v{d}, ", .{m.dst.vreg});
                    dumpMIROp(writer, m.src) catch {};
                },
                .add => |m| {
                    try writer.print("add v{d}, ", .{m.dst.vreg});
                    dumpMIROp(writer, m.src) catch {};
                },
                .sub => |m| {
                    try writer.print("sub v{d}, ", .{m.dst.vreg});
                    dumpMIROp(writer, m.src) catch {};
                },
                .imul => |m| {
                    try writer.print("imul v{d}, ", .{m.dst.vreg});
                    dumpMIROp(writer, m.src) catch {};
                },
                .idiv => |m| {
                    try writer.print("idiv v{d}, v{d} -> q:v{d} r:v{d}", .{ m.dividend.vreg, m.divisor.vreg, m.quotient.vreg, m.remainder.vreg });
                },
                .cmp => |m| {
                    try writer.print("cmp {s} ", .{@tagName(m.cc)});
                    dumpMIROp(writer, m.a) catch {};
                    try writer.print(", ", .{});
                    dumpMIROp(writer, m.b) catch {};
                },
                .cmp_flags => |m| {
                    try writer.print("cmp_flags ", .{});
                    dumpMIROp(writer, m.a) catch {};
                    try writer.print(", ", .{});
                    dumpMIROp(writer, m.b) catch {};
                },
                .jmp => |m| try writer.print("jmp b{d}", .{m.target}),
                .jcc => |m| try writer.print("jcc {s} b{d}", .{ @tagName(m.cc), m.target }),
                .alloca => |m| try writer.print("alloca v{d}", .{m.dst.vreg}),
                .load => |m| {
                    try writer.print("load v{d}, ", .{m.dst.vreg});
                    dumpMIROp(writer, m.ptr) catch {};
                },
                .store => |m| {
                    try writer.print("store ", .{});
                    dumpMIROp(writer, m.ptr) catch {};
                    try writer.print(", ", .{});
                    dumpMIROp(writer, m.src) catch {};
                },
                .call => |m| try writer.print("call v{d}", .{m.dst.vreg}),
                .ret => |m| switch (m) {
                    .void_ret => try writer.print("ret void", .{}),
                    .value => |v| {
                        try writer.print("ret ", .{});
                        dumpMIROp(writer, v) catch {};
                    },
                },
                .phi => |p| {
                    try writer.print("phi v{d}", .{p.dst.vreg});
                },
                else => {
                    try writer.print("{s}", .{@tagName(inst)});
                },
            }
            try writer.writeAll("\n");
        }
    }
}

fn dumpMIROp(writer: anytype, op: mir.MOperand) !void {
    switch (op) {
        .vreg => |v| try writer.print("v{d}", .{v}),
        .imm => |v| try writer.print("#{}", .{v}),
        .phys => |v| try writer.print("phys({d})", .{v}),
        .mem => |m| try writer.print("mem(base={d}+{d})", .{ m.base, m.offset }),
    }
}

// ─── Pipeline: BIR Module → MIR → regalloc → x86_64 code → execute ───

const PipelineResult = struct {
    code: []const u8,
    mfuncs: []mir.MFunction,

    fn deinit(self: *PipelineResult, alloc: std.mem.Allocator) void {
        for (self.mfuncs) |*mf| mf.deinit();
        alloc.free(self.mfuncs);
    }
};

fn runPipeline(alloc: std.mem.Allocator, mod: *bir.Module) !PipelineResult {
    const mfuncs = try bir_cpu.lowerModuleToMir(alloc, mod);
    errdefer {
        for (mfuncs) |*mf| mf.deinit();
        alloc.free(mfuncs);
    }

    const emit = try mir_x64.emitModule(mfuncs);
    return .{
        .code = try alloc.dupe(u8, emit.code.items),
        .mfuncs = mfuncs,
    };
}

// ─── Test 1: Simple const return ───
// BIR: fn main() -> i64 { entry: const 42, ret 42 }
// Expected: executable returns 42
fn testSimpleRetConst(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testSimpleRetConst ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const func_id = try mod.addFunction("main", i64_ty, .entry);
    const b0 = try mod.addBlock(func_id, "entry");

    const c42 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 42 } },
    });
    _ = try mod.addInst(func_id, b0, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{c42}),
        .data = .{ .none = {} },
    });

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  BIR: 1 block, MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 42)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 42), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 2: Simple add ───
// BIR: fn main() -> i64 { entry: const 10, const 20, add(10, 20), ret(sum) }
// Expected: executable returns 30
fn testSimpleAdd(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testSimpleAdd ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const func_id = try mod.addFunction("main", i64_ty, .entry);
    const b0 = try mod.addBlock(func_id, "entry");

    const c10 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
    });
    const c20 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 20 } },
    });
    const sum = try mod.addInst(func_id, b0, .{
        .op = .add, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ c10, c20 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b0, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{sum}),
        .data = .{ .none = {} },
    });

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  BIR: 1 block, MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 30)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 30), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 3: if/else — const branch ───
// BIR:
//   entry: const true, cond_br → if.then, if.else
//   if.then: const 10, br → if.merge
//   if.else: const 20, br → if.merge
//   if.merge: ret 0  (placeholder — we can't use phi here for simplicity)
//
// We test that branching compiles to valid x86_64 and executes.
// Since cond is true, we expect 10 (then branch), but ret is 0 in merge.
// Actually let's just verify it compiles and runs without crashing.
fn testIfElse(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testIfElse ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const i1_ty = try mod.types.scalarType(.i1);
    const func_id = try mod.addFunction("main", i64_ty, .entry);

    const b_entry = try mod.addBlock(func_id, "entry");
    const b_then = try mod.addBlock(func_id, "if.then");
    const b_else = try mod.addBlock(func_id, "if.else");
    const b_merge = try mod.addBlock(func_id, "if.merge");

    // entry: const true, cond_br
    const cond = try mod.addInst(func_id, b_entry, .{
        .op = .@"const", .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .bool = true } },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{cond}),
        .data = .{ .cond_branch = .{ .cond = cond, .then_block = b_then, .else_block = b_else } },
    });

    // if.then: const 10, br merge
    const c10 = try mod.addInst(func_id, b_then, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
    });
    _ = try mod.addInst(func_id, b_then, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_merge },
    });

    // if.else: const 20, br merge
    const c20 = try mod.addInst(func_id, b_else, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 20 } },
    });
    _ = try mod.addInst(func_id, b_else, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_merge },
    });

    // if.merge: const 0, ret
    const c0 = try mod.addInst(func_id, b_merge, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 0 } },
    });
    _ = try mod.addInst(func_id, b_merge, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{c0}),
        .data = .{ .none = {} },
    });

    _ = c10;
    _ = c20;

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 0)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 0), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 4: if/else with phi (mem2reg + BIR→MIR) ───
// BIR:
//   entry: alloca, const 10, const 20, const true, store 10, store 20, cond_br
//   if.then: store 10 → alloca, br merge
//   if.else: store 20 → alloca, br merge
//   if.merge: load → alloca, ret load_result
// After mem2reg: phi at merge
// After BIR→MIR: phi copies in predecessor blocks
// Expected: returns 10 (since cond = true → then branch)
fn testIfElseWithPhi(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testIfElseWithPhi ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const i1_ty = try mod.types.scalarType(.i1);
    const func_id = try mod.addFunction("main", i64_ty, .entry);

    const b_entry = try mod.addBlock(func_id, "entry");
    const b_then = try mod.addBlock(func_id, "if.then");
    const b_else = try mod.addBlock(func_id, "if.else");
    const b_merge = try mod.addBlock(func_id, "if.merge");

    // entry: alloca, const 10, const 20, cond, store 10, store 20, cond_br
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
    const cond = try mod.addInst(func_id, b_entry, .{
        .op = .@"const", .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .bool = true } },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c10 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c20 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{cond}),
        .data = .{ .cond_branch = .{ .cond = cond, .then_block = b_then, .else_block = b_else } },
    });

    // if.then: store 10 → alloca, br merge
    _ = try mod.addInst(func_id, b_then, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c10 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_then, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_merge },
    });

    // if.else: store 20 → alloca, br merge
    _ = try mod.addInst(func_id, b_else, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c20 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_else, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_merge },
    });

    // if.merge: load → alloca, ret load_result
    const loaded = try mod.addInst(func_id, b_merge, .{
        .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_merge, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{loaded}),
        .data = .{ .none = {} },
    });

    // Run mem2reg first
    var pm = bir.PassManager.init(alloc);
    defer pm.deinit();
    try pm.addPass(bir_mem2reg.Mem2RegPass);
    var am = bir.AnalysisManager.init(alloc, &mod);
    defer am.deinit();
    var ctx = bir.PassContext{
        .module = &mod,
        .analysis = &am,
        .allocator = alloc,
    };
    try pm.run(&ctx);

    try stdout.writeAll("  after mem2reg:\n");
    {
        const func_b = mod.getFunction(func_id);
        for (func_b.blocks.items, 0..) |blk, bi| {
            try stdout.print("    b{d} '{s}':\n", .{ bi, blk.label });
            for (blk.instrs.items) |inst| {
                if (inst.op == .phi) {
                    try stdout.print("      phi [", .{});
                    for (inst.data.phi_incoming, 0..) |inc, ii| {
                        if (ii > 0) try stdout.writeAll(", ");
                        try stdout.print("(v{d}, b{d})", .{ inc.value, inc.block });
                    }
                    try stdout.writeAll("]\n");
                } else {
                    try stdout.print("      {s} ops=[", .{@tagName(inst.op)});
                    for (inst.operands, 0..) |op, oi| {
                        if (oi > 0) try stdout.writeAll(", ");
                        try stdout.print("{d}", .{op});
                    }
                    try stdout.writeAll("]\n");
                }
            }
        }
    }

    // Now run the full pipeline: BIR → MIR → x86_64
    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 10)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 10), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 5: neg ───
// BIR: fn main() -> i64 { entry: const 5, neg(5), ret(neg_val) }
// Expected: executable returns -5
fn testNeg(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testNeg ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const func_id = try mod.addFunction("main", i64_ty, .entry);
    const b0 = try mod.addBlock(func_id, "entry");

    const c5 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 5 } },
    });
    const neg_val = try mod.addInst(func_id, b0, .{
        .op = .neg, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{c5}),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b0, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{neg_val}),
        .data = .{ .none = {} },
    });

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected -5)\n", .{actual});
    try std.testing.expectEqual(@as(i64, -5), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 6: Nested if with phi at inner and outer merge ───
// BIR:
//   entry: alloca, const 10/20, store 10, store 20, const true, cond_br → outer.then, outer.else
//   outer.then: const false, cond_br → inner.then, inner.else
//   inner.then: const 100, store 100, br inner.merge
//   inner.else: const 200, store 200, br inner.merge
//   inner.merge: load, br outer.merge
//   outer.else: const 300, store 300, br outer.merge
//   outer.merge: load, ret
// Path: entry → outer.then (true) → inner.else (false→else) → inner.merge → outer.merge
// Expected: 200
fn testNestedIfWithPhi(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testNestedIfWithPhi ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const i1_ty = try mod.types.scalarType(.i1);
    const func_id = try mod.addFunction("main", i64_ty, .entry);

    const b_entry = try mod.addBlock(func_id, "entry");
    const b_outer_then = try mod.addBlock(func_id, "outer.then");
    const b_outer_else = try mod.addBlock(func_id, "outer.else");
    const b_inner_then = try mod.addBlock(func_id, "inner.then");
    const b_inner_else = try mod.addBlock(func_id, "inner.else");
    const b_inner_merge = try mod.addBlock(func_id, "inner.merge");
    const b_outer_merge = try mod.addBlock(func_id, "outer.merge");

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
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c10 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c20 }),
        .data = .{ .none = {} },
    });
    const true_val = try mod.addInst(func_id, b_entry, .{
        .op = .@"const", .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .bool = true } },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{true_val}),
        .data = .{ .cond_branch = .{ .cond = true_val, .then_block = b_outer_then, .else_block = b_outer_else } },
    });

    const false_val = try mod.addInst(func_id, b_outer_then, .{
        .op = .@"const", .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .bool = false } },
    });
    _ = try mod.addInst(func_id, b_outer_then, .{
        .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{false_val}),
        .data = .{ .cond_branch = .{ .cond = false_val, .then_block = b_inner_then, .else_block = b_inner_else } },
    });

    const c100 = try mod.addInst(func_id, b_inner_then, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 100 } },
    });
    _ = try mod.addInst(func_id, b_inner_then, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c100 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_inner_then, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_inner_merge },
    });

    const c200 = try mod.addInst(func_id, b_inner_else, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 200 } },
    });
    _ = try mod.addInst(func_id, b_inner_else, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c200 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_inner_else, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_inner_merge },
    });

    _ = try mod.addInst(func_id, b_inner_merge, .{
        .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_inner_merge, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_outer_merge },
    });

    const c300 = try mod.addInst(func_id, b_outer_else, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 300 } },
    });
    _ = try mod.addInst(func_id, b_outer_else, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c300 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_outer_else, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_outer_merge },
    });

    const loaded = try mod.addInst(func_id, b_outer_merge, .{
        .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_outer_merge, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{loaded}),
        .data = .{ .none = {} },
    });

    var pm = bir.PassManager.init(alloc);
    defer pm.deinit();
    try pm.addPass(bir_mem2reg.Mem2RegPass);
    var am = bir.AnalysisManager.init(alloc, &mod);
    defer am.deinit();
    var ctx = bir.PassContext{ .module = &mod, .analysis = &am, .allocator = alloc };
    try pm.run(&ctx);

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 200)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 200), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 7: Loop with phi ───
// BIR: count from 0 to 10 using alloca + mem2reg phi
//   entry: alloca, const 0, store, br → header
//   header: load, const 10, cmp lt, cond_br → body, exit
//   body: load, const 1, add, store, br → header
//   exit: load, ret
// After mem2reg: phi at header merges 0 (entry) and sum (body)
// Expected: 10
fn testLoopWithPhi(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testLoopWithPhi ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const i1_ty = try mod.types.scalarType(.i1);
    const func_id = try mod.addFunction("main", i64_ty, .entry);

    const b_entry = try mod.addBlock(func_id, "entry");
    const b_header = try mod.addBlock(func_id, "header");
    const b_body = try mod.addBlock(func_id, "body");
    const b_exit = try mod.addBlock(func_id, "exit");

    const alloca_val = try mod.addInst(func_id, b_entry, .{
        .op = .alloca, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .none = {} },
    });
    const c0 = try mod.addInst(func_id, b_entry, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 0 } },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c0 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_header },
    });

    const c10 = try mod.addInst(func_id, b_header, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
    });
    const cur_header = try mod.addInst(func_id, b_header, .{
        .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
        .data = .{ .none = {} },
    });
    const cmp_lt = try mod.addInst(func_id, b_header, .{
        .op = .lt, .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ cur_header, c10 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_header, .{
        .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{cmp_lt}),
        .data = .{ .cond_branch = .{ .cond = cmp_lt, .then_block = b_body, .else_block = b_exit } },
    });

    const cur_body = try mod.addInst(func_id, b_body, .{
        .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
        .data = .{ .none = {} },
    });
    const c1 = try mod.addInst(func_id, b_body, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 1 } },
    });
    const next = try mod.addInst(func_id, b_body, .{
        .op = .add, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ cur_body, c1 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_body, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, next }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_body, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_header },
    });

    const cur_exit = try mod.addInst(func_id, b_exit, .{
        .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_exit, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{cur_exit}),
        .data = .{ .none = {} },
    });

    var pm = bir.PassManager.init(alloc);
    defer pm.deinit();
    try pm.addPass(bir_mem2reg.Mem2RegPass);
    var am = bir.AnalysisManager.init(alloc, &mod);
    defer am.deinit();
    var ctx = bir.PassContext{ .module = &mod, .analysis = &am, .allocator = alloc };
    try pm.run(&ctx);

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 10)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 10), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 8: Critical edge with phi ───
// BIR:
//   entry: alloca, const 10, store, const true, cond_br → then, else
//   then: br → merge
//   else: const false, cond_br → merge, other
//   other: const 20, store, br → merge
//   merge: load, ret
// The edge else→merge is critical (else has 2 succs, merge has 3 preds)
// Path: entry → then → merge
// Expected: 10
fn testCriticalEdgePhi(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCriticalEdgePhi ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const i1_ty = try mod.types.scalarType(.i1);
    const func_id = try mod.addFunction("main", i64_ty, .entry);

    const b_entry = try mod.addBlock(func_id, "entry");
    const b_then = try mod.addBlock(func_id, "then");
    const b_else = try mod.addBlock(func_id, "else");
    const b_other = try mod.addBlock(func_id, "other");
    const b_merge = try mod.addBlock(func_id, "merge");

    const alloca_val = try mod.addInst(func_id, b_entry, .{
        .op = .alloca, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .none = {} },
    });
    const c10 = try mod.addInst(func_id, b_entry, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c10 }),
        .data = .{ .none = {} },
    });
    const true_val = try mod.addInst(func_id, b_entry, .{
        .op = .@"const", .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .bool = true } },
    });
    _ = try mod.addInst(func_id, b_entry, .{
        .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{true_val}),
        .data = .{ .cond_branch = .{ .cond = true_val, .then_block = b_then, .else_block = b_else } },
    });

    _ = try mod.addInst(func_id, b_then, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_merge },
    });

    const false_val = try mod.addInst(func_id, b_else, .{
        .op = .@"const", .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .bool = false } },
    });
    _ = try mod.addInst(func_id, b_else, .{
        .op = .cond_br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{false_val}),
        .data = .{ .cond_branch = .{ .cond = false_val, .then_block = b_merge, .else_block = b_other } },
    });

    const c20 = try mod.addInst(func_id, b_other, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 20 } },
    });
    _ = try mod.addInst(func_id, b_other, .{
        .op = .store, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ alloca_val, c20 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_other, .{
        .op = .br, .ty = try mod.types.voidType(), .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .block_target = b_merge },
    });

    const loaded = try mod.addInst(func_id, b_merge, .{
        .op = .load, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{alloca_val}),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b_merge, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{loaded}),
        .data = .{ .none = {} },
    });

    var pm = bir.PassManager.init(alloc);
    defer pm.deinit();
    try pm.addPass(bir_mem2reg.Mem2RegPass);
    var am = bir.AnalysisManager.init(alloc, &mod);
    defer am.deinit();
    var ctx = bir.PassContext{ .module = &mod, .analysis = &am, .allocator = alloc };
    try pm.run(&ctx);

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 10)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 10), actual);
    try stdout.print("  PASS\n\n", .{});
}

// ─── Test 9: SCCP constant folding through comparison + select ───
// BIR:
//   entry: const 5, const 10, const 100, const 200, lt(5,10), select, ret
// After SCCP: lt → const true, select → const 100, ret 100
// Expected: 100
fn testOptComparison(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testOptComparison ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);
    const i1_ty = try mod.types.scalarType(.i1);
    const func_id = try mod.addFunction("main", i64_ty, .entry);
    const b0 = try mod.addBlock(func_id, "entry");

    const c5 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 5 } },
    });
    const c10 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 10 } },
    });
    const c100 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 100 } },
    });
    const c200 = try mod.addInst(func_id, b0, .{
        .op = .@"const", .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .const_data = .{ .int = 200 } },
    });
    const cmp_res = try mod.addInst(func_id, b0, .{
        .op = .lt, .ty = i1_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ c5, c10 }),
        .data = .{ .none = {} },
    });
    const sel_res = try mod.addInst(func_id, b0, .{
        .op = .select, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ cmp_res, c100, c200 }),
        .data = .{ .none = {} },
    });
    _ = try mod.addInst(func_id, b0, .{
        .op = .ret, .ty = i64_ty, .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{sel_res}),
        .data = .{ .none = {} },
    });

    // Run SCCP
    var pm = bir.PassManager.init(alloc);
    defer pm.deinit();
    try pm.addPass(bir_sccp.SCCPPass);
    var am = bir.AnalysisManager.init(alloc, &mod);
    defer am.deinit();
    var ctx = bir.PassContext{ .module = &mod, .analysis = &am, .allocator = alloc };
    try pm.run(&ctx);

    // Verify the fold
    {
        const func = mod.getFunction(func_id);
        const block = &func.blocks.items[0];
        // cmp_res should now be const true
        const cmp_inst = &block.instrs.items[4]; // lt at index 4
        try std.testing.expect(cmp_inst.op == .@"const");
        try std.testing.expect(cmp_inst.data.const_data.bool == true);
        // select should now be const 100
        const sel_inst = &block.instrs.items[5]; // select at index 5
        try std.testing.expect(sel_inst.op == .@"const");
        try std.testing.expect(sel_inst.data.const_data.int == 100);
    }

    var result = try runPipeline(alloc, &mod);
    defer result.deinit(alloc);

    try stdout.print("  MIR: {d} blocks, code: {d} bytes\n", .{
        result.mfuncs[0].blocks.items.len,
        result.code.len,
    });
    try dumpMIRInsts(stdout, &result.mfuncs[0]);

    try std.testing.expect(result.code.len > 0);

    const actual = executeCode(result.code);
    try stdout.print("  execute() returned: {d} (expected 100)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 100), actual);
    try stdout.print("  PASS\n\n", .{});
}
