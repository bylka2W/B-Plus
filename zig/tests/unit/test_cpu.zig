const std = @import("std");
const bir = @import("../../src/compiler/backend/bir/bir.zig");
const bir_cpu = @import("../../src/compiler/backend/bir/bir_cpu.zig");
const mir = @import("../../src/compiler/backend/mir/mir.zig");
const mir_x64 = @import("../../src/compiler/backend/mir/mir_x64.zig");
const coff = @import("../../src/compiler/backend/pe/coff.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    try testCpuArith(alloc, stdout);
    try testCpuCmp(alloc, stdout);
    try testCpuIfElse(alloc, stdout);
    try testCpuAlloca(alloc, stdout);
    try testCpuLoadStore(alloc, stdout);
    try testCpuLoop(alloc, stdout);
    try testCpuCall(alloc, stdout);
    try testCrossCall(alloc, stdout);
    try testCpuSpill(alloc, stdout);
    try testCpuSpillLoop(alloc, stdout);
    try testCpuCallSpill(alloc, stdout);
    try testBirAddArgs(alloc, stdout);
    try testBirPipelineAdd(alloc, stdout);
    try testCoffOutput(alloc, stdout);
}

fn testBirPipelineAdd(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testBirPipelineAdd (BIR → MIR → x64, fn add(a,b) -> a+b) ---\n");

    var mod = bir.Module.init(alloc);
    defer mod.deinit();

    const i64_ty = try mod.types.scalarType(.i64);

    // fn add(a: i64, b: i64) -> i64 { return a + b; }
    const add_id = try mod.addFunction("add", i64_ty, .internal);
    {
        const func = mod.getFunctionMut(add_id);
        func.param_values = try alloc.dupe(bir.ValueId, &.{
            func.createValue(), // v1 = a
            func.createValue(), // v2 = b
        });
    }
    const add_block = try mod.addBlock(add_id, "entry");
    // v3 = add v1, v2
    _ = try mod.addInst(add_id, add_block, .{
        .op = .add,
        .ty = i64_ty,
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{ 1, 2 }),
        .data = .{ .none = {} },
    });
    // ret v3
    _ = try mod.addInst(add_id, add_block, .{
        .op = .ret,
        .ty = i64_ty,
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{3}),
        .data = .{ .none = {} },
    });

    // fn main() -> i64 { return add(20, 22); }
    const main_id = try mod.addFunction("main", i64_ty, .internal);
    const main_block = try mod.addBlock(main_id, "entry");
    // v1 = const 20
    _ = try mod.addInst(main_id, main_block, .{
        .op = .@"const",
        .ty = i64_ty,
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{}),
        .data = .{ .const_data = .{ .int = 20 } },
    });
    // v2 = const 22
    _ = try mod.addInst(main_id, main_block, .{
        .op = .@"const",
        .ty = i64_ty,
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{}),
        .data = .{ .const_data = .{ .int = 22 } },
    });
    // v3 = call add(v1, v2)
    _ = try mod.addInst(main_id, main_block, .{
        .op = .call,
        .ty = i64_ty,
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{}),
        .data = .{ .named_call = .{ .name = try alloc.dupe(u8, "add"), .args = try alloc.dupe(bir.ValueId, &.{ 1, 2 }) } },
    });
    // ret v3
    _ = try mod.addInst(main_id, main_block, .{
        .op = .ret,
        .ty = i64_ty,
        .result = bir.NO_VALUE,
        .operands = try alloc.dupe(bir.ValueId, &.{3}),
        .data = .{ .none = {} },
    });

    mod.entry_point = main_id;

    // Lower BIR → MIR
    const mfuncs = try bir_cpu.lowerModuleToMir(alloc, &mod);
    defer alloc.free(mfuncs);
    defer for (mfuncs) |*mf| mf.deinit();

    // Emit MIR → x64
    var result = try mir_x64.emitModule(mfuncs);
    defer result.code.deinit();

    const w = std.os.windows;
    const mem = try w.VirtualAlloc(null, result.code.items.len, w.MEM_COMMIT | w.MEM_RESERVE, w.PAGE_EXECUTE_READWRITE);
    defer _ = w.VirtualFree(mem, 0, w.MEM_RELEASE);
    @memcpy(@as([*]u8, @ptrCast(mem))[0..result.code.items.len], result.code.items);

    const entry_ptr = @as([*]u8, @ptrCast(mem)) + result.entry_offset;
    const func: *const fn () callconv(.C) i64 = @ptrCast(@alignCast(entry_ptr));
    const actual = func();
    try stdout.print("  add(20, 22) = {d} (expected 42)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 42), actual);
    try stdout.print("  OK\n", .{});
}

fn testCoffOutput(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCoffOutput (COFF .obj → exe, ret 42) ---\n");

    const zig_exe = "C:\\tools\\zig\\zig-windows-x86_64-0.14.0\\zig.exe";

    // Build MIR module: main() → 42
    var mfuncs = std.ArrayList(mir.MFunction).init(alloc);
    defer mfuncs.deinit();
    defer for (mfuncs.items) |*mf| mf.deinit();

    {
        var main_func = mir.MFunction.init(alloc, "main");
        try main_func.blocks.append(.{
            .label = try alloc.dupe(u8, "entry"),
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
        const b = &main_func.blocks.items[0];
        try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 1 }, .src = .{ .imm = 42 } } });
        try b.instrs.append(.{ .ret = .{ .val = .{ .vreg = 1 } } });
        try mfuncs.append(main_func);
    }

    // Emit COFF .obj
    const coff_result = try coff.emitCoff(mfuncs.items);
    defer coff_result.bytes.deinit();

    // Use temp dir for output files
    const tmp_dir_path = "C:\\Users\\Local\\AppData\\Local\\Temp\\opencode";
    const tmp_dir = try std.fs.openDirAbsolute(tmp_dir_path, .{});
    const obj_name = "test_coff_output.obj";
    const exe_name = "test_coff_output.exe";

    // Clean up any previous files
    _ = tmp_dir.deleteFile(obj_name) catch {};
    _ = tmp_dir.deleteFile(exe_name) catch {};

    try tmp_dir.writeFile(.{ .sub_path = obj_name, .data = coff_result.bytes.items });

    // Run zig build-exe to link
    const obj_path = try std.fs.path.join(alloc, &.{ tmp_dir_path, obj_name });
    defer alloc.free(obj_path);
    const exe_path = try std.fs.path.join(alloc, &.{ tmp_dir_path, exe_name });
    defer alloc.free(exe_path);

    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.append(zig_exe);
    try argv.append("build-exe");
    try argv.append(obj_path);
    try argv.append("-fentry=main");
    try argv.append("--subsystem");
    try argv.append("console");
    try argv.append("-femit-bin");
    const emit_flag = try std.fmt.allocPrint(alloc, "-femit-bin={s}", .{exe_path});
    defer alloc.free(emit_flag);
    try argv.append(emit_flag);
    try argv.append("--cache-dir");
    try argv.append(tmp_dir_path);

    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stderr_data = try child.stderr.?.reader().readAllAlloc(alloc, 1024 * 16);
    defer alloc.free(stderr_data);
    const term = try child.wait();
    if (term.Exited != 0) {
        try stdout.print("  zig build-exe failed (exit {d}):\n  {s}\n", .{ term.Exited, std.mem.trimRight(u8, stderr_data, " \r\n") });
        return error.TestFailed;
    }

    // Run the .exe from temp dir
    var run_argv = std.ArrayList([]const u8).init(alloc);
    defer run_argv.deinit();
    try run_argv.append(exe_path);

    var run_child = std.process.Child.init(run_argv.items, alloc);
    run_child.stdout_behavior = .Ignore;
    run_child.stderr_behavior = .Ignore;
    const run_term = try run_child.spawnAndWait();

    try std.testing.expectEqual(@as(i32, 42), run_term.Exited);
    try stdout.print("  exit code: {d} (expected 42) OK\n", .{run_term.Exited});

    // Cleanup
    _ = tmp_dir.deleteFile(obj_name) catch {};
    _ = tmp_dir.deleteFile(exe_name) catch {};
}

fn testBirAddArgs(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testBirAddArgs (fn add(a,b) -> a+b) ---\n");

    var mfuncs = std.ArrayList(mir.MFunction).init(alloc);
    errdefer for (mfuncs.items) |*mf| mf.deinit();

    // fn add(a: i64, b: i64) -> i64 { return a + b; }
    {
        var add_func = mir.MFunction.init(alloc, "add");
        try add_func.blocks.append(.{
            .label = try alloc.dupe(u8, "entry"),
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
        {
            const b = &add_func.blocks.items[0];
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 3 }, .src = .{ .vreg = 1 } } });
            try b.instrs.append(.{ .add = .{ .dst = .{ .vreg = 3 }, .src = .{ .vreg = 2 } } });
            try b.instrs.append(.{ .ret = .{ .val = .{ .vreg = 3 } } });
        }
        const add_params = try alloc.alloc(mir.MOperand, 2);
        add_params[0] = .{ .vreg = 1 };
        add_params[1] = .{ .vreg = 2 };
        add_func.setParams(add_params);
        try mfuncs.append(add_func);
    }

    // fn main() -> i64 { return add(20, 22); }
    {
        var main_func = mir.MFunction.init(alloc, "main");
        try main_func.blocks.append(.{
            .label = try alloc.dupe(u8, "entry"),
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
        {
            const b = &main_func.blocks.items[0];
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 1 }, .src = .{ .imm = 20 } } });
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 2 }, .src = .{ .imm = 22 } } });
            const fn_name = try alloc.dupe(u8, "add");
            try b.instrs.append(.{ .call = .{
                .name = fn_name,
                .args = .{ .{ .vreg = 1 }, .{ .vreg = 2 }, .{ .imm = 0 }, .{ .imm = 0 } },
                .arg_count = 2,
                .dst = .{ .vreg = 3 },
            } });
            try b.instrs.append(.{ .ret = .{ .val = .{ .vreg = 3 } } });
        }
        try mfuncs.append(main_func);
    }

    var result = try mir_x64.emitModule(mfuncs.items);
    defer result.code.deinit();

    const w = std.os.windows;
    const mem = try w.VirtualAlloc(null, result.code.items.len, w.MEM_COMMIT | w.MEM_RESERVE, w.PAGE_EXECUTE_READWRITE);
    defer _ = w.VirtualFree(mem, 0, w.MEM_RELEASE);
    @memcpy(@as([*]u8, @ptrCast(mem))[0..result.code.items.len], result.code.items);

    const entry_ptr = @as([*]u8, @ptrCast(mem)) + result.entry_offset;
    const func: *const fn () callconv(.C) i64 = @ptrCast(@alignCast(entry_ptr));
    const actual = func();
    try stdout.print("  add(20, 22) = {d} (expected 42)\n", .{actual});
    try std.testing.expectEqual(@as(i64, 42), actual);
    try stdout.print("  OK\n", .{});
}

fn buildArithFunc(alloc: std.mem.Allocator, op: bir.Op, b: i64) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    const v1 = func.createValue();
    const v2 = func.createValue();
    const v3 = func.createValue();
    const v4 = func.createValue();

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "entry"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    const block = &func.blocks.items[0];
    try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 42 } } });
    try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v2, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = b } } });
    try block.instrs.append(.{ .op = op, .ty = i32_ty, .result = v3, .operands = try alloc.dupe(bir.ValueId, &.{ v1, v2 }), .data = .{ .none = {} } });
    try block.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = v4, .operands = try alloc.dupe(bir.ValueId, &.{v3}), .data = .{ .none = {} } });
    return mod;
}

fn buildCmpFunc(alloc: std.mem.Allocator, op: bir.Op) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    const v1 = func.createValue();
    const v2 = func.createValue();
    const v3 = func.createValue();
    const v4 = func.createValue();

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "entry"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    const block = &func.blocks.items[0];
    try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 10 } } });
    try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v2, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 20 } } });
    try block.instrs.append(.{ .op = op, .ty = i32_ty, .result = v3, .operands = try alloc.dupe(bir.ValueId, &.{ v1, v2 }), .data = .{ .none = {} } });
    try block.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = v4, .operands = try alloc.dupe(bir.ValueId, &.{v3}), .data = .{ .none = {} } });
    return mod;
}

fn runAndPrint(alloc: std.mem.Allocator, stdout: anytype, label: []const u8, mod: *bir.Module) !void {
    try stdout.print("  {s}: ", .{label});
    const func = mod.getFunction(0);
    var mfunc = try bir_cpu.lowerToMir(alloc, &mod.types, func);
    defer mfunc.deinit();
    var result = try mir_x64.emitModule(&[_]mir.MFunction{mfunc});
    defer result.code.deinit();
    try stdout.print("{d} bytes: ", .{ result.code.items.len });
    for (result.code.items) |b| try stdout.print("{x:0>2} ", .{b});
    try stdout.print("\n", .{});
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

fn runAndExec(alloc: std.mem.Allocator, mod: *bir.Module) !i64 {
    const func = mod.getFunction(0);
    var mfunc = try bir_cpu.lowerToMir(alloc, &mod.types, func);
    defer mfunc.deinit();
    var result = try mir_x64.emitModule(&[_]mir.MFunction{mfunc});
    defer result.code.deinit();
    return executeCode(result.code.items);
}

fn testCpuArith(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuArith ---\n");

    var mod = try buildArithFunc(alloc, .add, 5);
    defer mod.deinit();
    try runAndPrint(alloc, stdout, "add", &mod);
    try std.testing.expectEqual(@as(i64, 47), try runAndExec(alloc, &mod));

    var mod2 = try buildArithFunc(alloc, .sub, 5);
    defer mod2.deinit();
    try runAndPrint(alloc, stdout, "sub", &mod2);
    try std.testing.expectEqual(@as(i64, 37), try runAndExec(alloc, &mod2));

    var mod3 = try buildArithFunc(alloc, .mul, 5);
    defer mod3.deinit();
    try runAndPrint(alloc, stdout, "mul", &mod3);
    try std.testing.expectEqual(@as(i64, 210), try runAndExec(alloc, &mod3));

    try stdout.print("  OK\n", .{});
}

fn buildIfElseFunc(alloc: std.mem.Allocator, cond_op: bir.Op) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    const v1 = func.createValue();
    const v2 = func.createValue();
    const v3 = func.createValue();
    const v4 = func.createValue();
    const v5 = func.createValue();
    const v6 = func.createValue();
    const v7 = func.createValue();

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "entry"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "then"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "else"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    {
        const b = &func.blocks.items[0];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 10 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v2, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 20 } } });
        try b.instrs.append(.{ .op = cond_op, .ty = i32_ty, .result = v3, .operands = try alloc.dupe(bir.ValueId, &.{ v1, v2 }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .cond_br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{v3}), .data = .{ .cond_branch = .{ .cond = v3, .then_block = 1, .else_block = 2 } } });
    }

    {
        const b = &func.blocks.items[1];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v4, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 1 } } });
        try b.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = v5, .operands = try alloc.dupe(bir.ValueId, &.{v4}), .data = .{ .none = {} } });
    }

    {
        const b = &func.blocks.items[2];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v6, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 2 } } });
        try b.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = v7, .operands = try alloc.dupe(bir.ValueId, &.{v6}), .data = .{ .none = {} } });
    }

    return mod;
}

fn testCpuCmp(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuCmp ---\n");

    var mod = try buildCmpFunc(alloc, .lt);
    defer mod.deinit();
    try runAndPrint(alloc, stdout, "lt", &mod);
    try std.testing.expectEqual(@as(i64, 1), try runAndExec(alloc, &mod));

    var mod2 = try buildCmpFunc(alloc, .le);
    defer mod2.deinit();
    try runAndPrint(alloc, stdout, "le", &mod2);
    try std.testing.expectEqual(@as(i64, 1), try runAndExec(alloc, &mod2));

    var mod3 = try buildCmpFunc(alloc, .gt);
    defer mod3.deinit();
    try runAndPrint(alloc, stdout, "gt", &mod3);
    try std.testing.expectEqual(@as(i64, 0), try runAndExec(alloc, &mod3));

    var mod4 = try buildCmpFunc(alloc, .ge);
    defer mod4.deinit();
    try runAndPrint(alloc, stdout, "ge", &mod4);
    try std.testing.expectEqual(@as(i64, 0), try runAndExec(alloc, &mod4));

    var mod5 = try buildCmpFunc(alloc, .eq);
    defer mod5.deinit();
    try runAndPrint(alloc, stdout, "eq", &mod5);
    try std.testing.expectEqual(@as(i64, 0), try runAndExec(alloc, &mod5));

    var mod6 = try buildCmpFunc(alloc, .ne);
    defer mod6.deinit();
    try runAndPrint(alloc, stdout, "ne", &mod6);
    try std.testing.expectEqual(@as(i64, 1), try runAndExec(alloc, &mod6));

    try stdout.print("  OK\n", .{});
}

fn testCpuIfElse(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuIfElse ---\n");

    var mod = try buildIfElseFunc(alloc, .lt);
    defer mod.deinit();
    try runAndPrint(alloc, stdout, "if/else", &mod);
    try std.testing.expectEqual(@as(i64, 1), try runAndExec(alloc, &mod));

    try stdout.print("  OK\n", .{});
}

fn buildAllocaFunc(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const ptr_ty = try mod.types.pointerType(i32_ty, .generic);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    const v1 = func.createValue();
    const v2 = func.createValue();

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "entry"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    const block = &func.blocks.items[0];
    try block.instrs.append(.{ .op = .alloca, .ty = ptr_ty, .result = v1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .none = {} } });
    try block.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = v2, .operands = try alloc.dupe(bir.ValueId, &.{v1}), .data = .{ .none = {} } });
    return mod;
}

fn testCpuAlloca(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuAlloca ---\n");

    var mod = try buildAllocaFunc(alloc);
    defer mod.deinit();
    try runAndPrint(alloc, stdout, "alloca", &mod);
    const ptr_val = try runAndExec(alloc, &mod);
    try std.testing.expect(ptr_val != 0);

    try stdout.print("  OK\n", .{});
}

fn buildLoadStoreFunc(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const ptr_ty = try mod.types.pointerType(i32_ty, .generic);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    const v1 = func.createValue();
    const v2 = func.createValue();
    const v3 = func.createValue();
    const v4 = func.createValue();
    const v5 = func.createValue();

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "entry"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    const block = &func.blocks.items[0];
    try block.instrs.append(.{ .op = .alloca, .ty = ptr_ty, .result = v1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .none = {} } });
    try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v2, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 42 } } });
    try block.instrs.append(.{ .op = .store, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{ v1, v2 }), .data = .{ .none = {} } });
    try block.instrs.append(.{ .op = .load, .ty = i32_ty, .result = v3, .operands = try alloc.dupe(bir.ValueId, &.{v1}), .data = .{ .none = {} } });
    try block.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = v4, .operands = try alloc.dupe(bir.ValueId, &.{v3}), .data = .{ .none = {} } });
    _ = v5;
    return mod;
}

fn testCpuLoadStore(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuLoadStore ---\n");

    var mod = try buildLoadStoreFunc(alloc);
    defer mod.deinit();
    try runAndPrint(alloc, stdout, "load/store", &mod);
    try std.testing.expectEqual(@as(i64, 42), try runAndExec(alloc, &mod));

    try stdout.print("  OK\n", .{});
}

fn buildLoopFunc(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    const vi = func.createValue();
    const vsum = func.createValue();
    const vc4 = func.createValue();
    const vcond = func.createValue();
    const vc1_body = func.createValue();
    const vc1_latch = func.createValue();
    const vsum_next = func.createValue();
    const vi_next = func.createValue();

    const v_i_phi = func.createValue();
    const v_sum_phi = func.createValue();

    try func.blocks.append(.{ .label = try alloc.dupe(u8, "entry"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "header"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "body"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "latch"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "exit"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });

    {
        const b = &func.blocks.items[0];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vi, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vsum, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .block_target = 1 } });
    }

    {
        const b = &func.blocks.items[1];
        const inc1 = try alloc.alloc(bir.PhiIncoming, 2);
        inc1[0] = .{ .value = vi, .block = 0 };
        inc1[1] = .{ .value = vi_next, .block = 3 };
        try b.instrs.append(.{ .op = .phi, .ty = i32_ty, .result = v_i_phi, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .phi_incoming = inc1 } });
        const inc2 = try alloc.alloc(bir.PhiIncoming, 2);
        inc2[0] = .{ .value = vsum, .block = 0 };
        inc2[1] = .{ .value = vsum_next, .block = 3 };
        try b.instrs.append(.{ .op = .phi, .ty = i32_ty, .result = v_sum_phi, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .phi_incoming = inc2 } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vc4, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 4 } } });
        try b.instrs.append(.{ .op = .lt, .ty = i32_ty, .result = vcond, .operands = try alloc.dupe(bir.ValueId, &.{ v_i_phi, vc4 }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .cond_br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{vcond}), .data = .{ .cond_branch = .{ .cond = vcond, .then_block = 2, .else_block = 4 } } });
    }

    {
        const b = &func.blocks.items[2];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vc1_body, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 1 } } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = vsum_next, .operands = try alloc.dupe(bir.ValueId, &.{ v_sum_phi, vc1_body }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .block_target = 3 } });
    }

    {
        const b = &func.blocks.items[3];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vc1_latch, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 1 } } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = vi_next, .operands = try alloc.dupe(bir.ValueId, &.{ v_i_phi, vc1_latch }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .block_target = 1 } });
    }

    {
        const b = &func.blocks.items[4];
        try b.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{v_sum_phi}), .data = .{ .none = {} } });
    }

    return mod;
}

fn testCpuLoop(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuLoop ---\n");

    var mod = try buildLoopFunc(alloc);
    defer mod.deinit();
    try runAndPrint(alloc, stdout, "loop", &mod);
    try std.testing.expectEqual(@as(i64, 4), try runAndExec(alloc, &mod));

    try stdout.print("  OK\n", .{});
}

fn testCrossCall(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCrossCall ---\n");

    var mfuncs = std.ArrayList(mir.MFunction).init(alloc);
    errdefer for (mfuncs.items) |*mf| mf.deinit();

    {
        var add_func = mir.MFunction.init(alloc, "add");
        try add_func.blocks.append(.{
            .label = try alloc.dupe(u8, "entry"),
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
        {
            const b = &add_func.blocks.items[0];
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 3 }, .src = .{ .vreg = 1 } } });
            try b.instrs.append(.{ .add = .{ .dst = .{ .vreg = 3 }, .src = .{ .vreg = 2 } } });
            try b.instrs.append(.{ .ret = .{ .val = .{ .vreg = 3 } } });
        }
        const add_params = try alloc.alloc(mir.MOperand, 2);
        add_params[0] = .{ .vreg = 1 };
        add_params[1] = .{ .vreg = 2 };
        add_func.setParams(add_params);
        try mfuncs.append(add_func);
    }

    {
        var main_func = mir.MFunction.init(alloc, "main");
        try main_func.blocks.append(.{
            .label = try alloc.dupe(u8, "entry"),
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
        {
            const b = &main_func.blocks.items[0];
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 1 }, .src = .{ .imm = 3 } } });
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 2 }, .src = .{ .imm = 7 } } });
            const fn_name = try alloc.dupe(u8, "add");
            try b.instrs.append(.{ .call = .{
                .name = fn_name,
                .args = .{ .{ .vreg = 1 }, .{ .vreg = 2 }, .{ .imm = 0 }, .{ .imm = 0 } },
                .arg_count = 2,
                .dst = .{ .vreg = 3 },
            } });
            try b.instrs.append(.{ .ret = .{ .val = .{ .vreg = 3 } } });
        }
        try mfuncs.append(main_func);
    }

    var result = try mir_x64.emitModule(mfuncs.items);
    defer result.code.deinit();

    const code_bytes = result.code.items;
    try stdout.print("  {d} bytes, entry @ {d}:\n", .{ code_bytes.len, result.entry_offset });
    for (code_bytes, 0..) |b, i| {
        if (i % 16 == 0) try stdout.print("    ", .{});
        try stdout.print("{x:0>2} ", .{b});
        if (i % 16 == 15) try stdout.print("\n", .{});
    }
    if (code_bytes.len % 16 != 0) try stdout.print("\n", .{});

    const w = std.os.windows;
    const exec_mem = try w.VirtualAlloc(null, code_bytes.len, w.MEM_COMMIT | w.MEM_RESERVE, w.PAGE_EXECUTE_READWRITE);
    defer _ = w.VirtualFree(exec_mem, 0, w.MEM_RELEASE);
    @memcpy(@as([*]u8, @ptrCast(exec_mem))[0..code_bytes.len], code_bytes);

    const entry_ptr = @as([*]u8, @ptrCast(exec_mem)) + result.entry_offset;
    const func: *const fn () callconv(.C) i64 = @ptrCast(@alignCast(entry_ptr));
    const main_ret = func();
    try stdout.print("  result: {d}\n", .{main_ret});
    try std.testing.expectEqual(@as(i64, 10), main_ret);

    try stdout.print("  OK\n", .{});
}

fn buildCallFunc(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    const v1 = func.createValue();
    const v2 = func.createValue();
    const v3 = func.createValue();
    const v4 = func.createValue();

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "entry"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });

    const block = &func.blocks.items[0];
    try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 3 } } });
    try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v2, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 7 } } });
    const fn_name = try alloc.dupe(u8, "my_func");
    const args = try alloc.dupe(bir.ValueId, &.{ v1, v2 });
    try block.instrs.append(.{ .op = .call, .ty = i32_ty, .result = v3, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .named_call = .{ .name = fn_name, .args = args } } });
    try block.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = v4, .operands = try alloc.dupe(bir.ValueId, &.{v3}), .data = .{ .none = {} } });
    return mod;
}

fn testCpuCall(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuCall ---\n");

    var mod = try buildCallFunc(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var mfunc = try bir_cpu.lowerToMir(alloc, &mod.types, func);
    defer mfunc.deinit();

    try std.testing.expectError(error.UnresolvedCallTarget, mir_x64.emitModule(&[_]mir.MFunction{mfunc}));

    try stdout.print("  OK (unresolved call detected)\n", .{});
}

fn buildSpillFunc(alloc: std.mem.Allocator, n: u32) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    try func.blocks.append(.{
        .label = try alloc.dupe(u8, "entry"),
        .instrs = std.ArrayList(bir.Inst).init(alloc),
        .next_value_id = 0,
        .loop = null,
    });
    const block = &func.blocks.items[0];

    var const_vals = std.ArrayList(bir.ValueId).init(alloc);
    defer const_vals.deinit();

    for (0..n) |i| {
        const v = func.createValue();
        try const_vals.append(v);
        try block.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = @as(i64, @intCast(i + 1)) } } });
    }

    var acc = const_vals.items[0];
    for (1..n) |i| {
        const v = func.createValue();
        try block.instrs.append(.{ .op = .add, .ty = i32_ty, .result = v, .operands = try alloc.dupe(bir.ValueId, &.{ acc, const_vals.items[i] }), .data = .{ .none = {} } });
        acc = v;
    }

    const ret_v = func.createValue();
    try block.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = ret_v, .operands = try alloc.dupe(bir.ValueId, &.{acc}), .data = .{ .none = {} } });

    return mod;
}

fn testCpuSpill(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuSpill (16 vars) ---\n");

    var mod = try buildSpillFunc(alloc, 16);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var mfunc = try bir_cpu.lowerToMir(alloc, &mod.types, func);
    defer mfunc.deinit();
    var result = try mir_x64.emitModule(&[_]mir.MFunction{mfunc});
    defer result.code.deinit();

    const w = std.os.windows;
    const mem = try w.VirtualAlloc(null, result.code.items.len, w.MEM_COMMIT | w.MEM_RESERVE, w.PAGE_EXECUTE_READWRITE);
    defer _ = w.VirtualFree(mem, 0, w.MEM_RELEASE);
    @memcpy(@as([*]u8, @ptrCast(mem))[0..result.code.items.len], result.code.items);
    const func_ptr: *const fn () callconv(.C) i64 = @ptrCast(@alignCast(mem));

    const expected: i64 = @as(i64, @intCast((16 * 17) / 2)); // sum 1..16 = 136
    const actual = func_ptr();
    try stdout.print("  result: {d} (expected {d})\n", .{ actual, expected });
    try std.testing.expectEqual(expected, actual);
    try stdout.print("  OK\n", .{});
}

fn buildSpillLoopFunc(alloc: std.mem.Allocator) !bir.Module {
    var mod = bir.Module.init(alloc);
    const i32_ty = try mod.types.scalarType(.i32);
    const func_id = try mod.addFunction("main", i32_ty, .internal);
    const func = mod.getFunctionMut(func_id);

    // Sum 1..100 with many live values in the loop
    const vi = func.createValue();
    const vn = func.createValue();
    const vsum = func.createValue();
    const vi_next = func.createValue();
    const vsum_next = func.createValue();
    const vcond = func.createValue();
    const vc1 = func.createValue();
    const v100 = func.createValue();

    // Extra live values to create register pressure
    const ve1 = func.createValue();
    const ve2 = func.createValue();
    const ve3 = func.createValue();
    const ve4 = func.createValue();
    const ve5 = func.createValue();
    const ve6 = func.createValue();
    const ve7 = func.createValue();
    const ve8 = func.createValue();

    // phi nodes
    const v_i_phi = func.createValue();
    const v_sum_phi = func.createValue();

    try func.blocks.append(.{ .label = try alloc.dupe(u8, "entry"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "header"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "body"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "latch"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });
    try func.blocks.append(.{ .label = try alloc.dupe(u8, "exit"), .instrs = std.ArrayList(bir.Inst).init(alloc), .next_value_id = 0, .loop = null });

    // entry: i=0, sum=0, extra=42
    {
        const b = &func.blocks.items[0];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vi, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vsum, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve2, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve3, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve4, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve5, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve6, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve7, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = ve8, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 0 } } });
        try b.instrs.append(.{ .op = .br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .block_target = 1 } });
    }

    // header: phi, check i < 100
    {
        const b = &func.blocks.items[1];
        const inc1 = try alloc.alloc(bir.PhiIncoming, 2);
        inc1[0] = .{ .value = vi, .block = 0 };
        inc1[1] = .{ .value = vi_next, .block = 3 };
        try b.instrs.append(.{ .op = .phi, .ty = i32_ty, .result = v_i_phi, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .phi_incoming = inc1 } });
        const inc2 = try alloc.alloc(bir.PhiIncoming, 2);
        inc2[0] = .{ .value = vsum, .block = 0 };
        inc2[1] = .{ .value = vsum_next, .block = 3 };
        try b.instrs.append(.{ .op = .phi, .ty = i32_ty, .result = v_sum_phi, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .phi_incoming = inc2 } });
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = v100, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 100 } } });
        try b.instrs.append(.{ .op = .lt, .ty = i32_ty, .result = vcond, .operands = try alloc.dupe(bir.ValueId, &.{ v_i_phi, v100 }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .cond_br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{vcond}), .data = .{ .cond_branch = .{ .cond = vcond, .then_block = 2, .else_block = 4 } } });
    }

    // body: sum += i, use all extra vars to keep them live
    {
        const b = &func.blocks.items[2];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vc1, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 1 } } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = vsum_next, .operands = try alloc.dupe(bir.ValueId, &.{ v_sum_phi, v_i_phi }), .data = .{ .none = {} } });
        // Touch all extra vars to keep them live across the loop
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve1, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve2, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve3, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve4, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve5, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve6, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve7, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{ ve8, v_i_phi }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .block_target = 3 } });
    }

    // latch: i += 1
    {
        const b = &func.blocks.items[3];
        try b.instrs.append(.{ .op = .@"const", .ty = i32_ty, .result = vn, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .const_data = .{ .int = 1 } } });
        try b.instrs.append(.{ .op = .add, .ty = i32_ty, .result = vi_next, .operands = try alloc.dupe(bir.ValueId, &.{ v_i_phi, vn }), .data = .{ .none = {} } });
        try b.instrs.append(.{ .op = .br, .ty = i32_ty, .result = bir.NO_VALUE, .operands = try alloc.dupe(bir.ValueId, &.{}), .data = .{ .block_target = 1 } });
    }

    // exit: return sum
    {
        const b = &func.blocks.items[4];
        try b.instrs.append(.{ .op = .ret, .ty = i32_ty, .result = func.createValue(), .operands = try alloc.dupe(bir.ValueId, &.{v_sum_phi}), .data = .{ .none = {} } });
    }

    return mod;
}

fn testCpuSpillLoop(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuSpillLoop (sum 0..99) ---\n");

    var mod = try buildSpillLoopFunc(alloc);
    defer mod.deinit();

    const func = mod.getFunction(0);
    var mfunc = try bir_cpu.lowerToMir(alloc, &mod.types, func);
    defer mfunc.deinit();
    var result = try mir_x64.emitModule(&[_]mir.MFunction{mfunc});
    defer result.code.deinit();

    const w = std.os.windows;
    const mem = try w.VirtualAlloc(null, result.code.items.len, w.MEM_COMMIT | w.MEM_RESERVE, w.PAGE_EXECUTE_READWRITE);
    defer _ = w.VirtualFree(mem, 0, w.MEM_RELEASE);
    @memcpy(@as([*]u8, @ptrCast(mem))[0..result.code.items.len], result.code.items);
    const func_ptr: *const fn () callconv(.C) i64 = @ptrCast(@alignCast(mem));

    const expected: i64 = @as(i64, @intCast((99 * 100) / 2)); // sum 0..99 = 4950
    const actual = func_ptr();
    try stdout.print("  result: {d} (expected {d})\n", .{ actual, expected });
    try std.testing.expectEqual(expected, actual);
    try stdout.print("  OK\n", .{});
}

fn buildCallSpillFunc(alloc: std.mem.Allocator) !struct { std.ArrayList(mir.MFunction), i64 } {
    var mfuncs = std.ArrayList(mir.MFunction).init(alloc);
    errdefer for (mfuncs.items) |*mf| mf.deinit();

    {
        var add7_func = mir.MFunction.init(alloc, "add7");
        try add7_func.blocks.append(.{
            .label = try alloc.dupe(u8, "entry"),
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
        {
            const b = &add7_func.blocks.items[0];
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 3 }, .src = .{ .vreg = 1 } } });
            try b.instrs.append(.{ .add = .{ .dst = .{ .vreg = 3 }, .src = .{ .imm = 7 } } });
            try b.instrs.append(.{ .ret = .{ .val = .{ .vreg = 3 } } });
        }
        const params = try alloc.alloc(mir.MOperand, 1);
        params[0] = .{ .vreg = 1 };
        add7_func.setParams(params);
        try mfuncs.append(add7_func);
    }

    {
        var main_func = mir.MFunction.init(alloc, "main");
        try main_func.blocks.append(.{
            .label = try alloc.dupe(u8, "entry"),
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
        const b = &main_func.blocks.items[0];

        for (0..16) |i| {
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = @intCast(i + 1) }, .src = .{ .imm = @intCast(i + 1) } } });
        }

        const fn_name = try alloc.dupe(u8, "add7");
        try b.instrs.append(.{ .call = .{
            .name = fn_name,
            .args = .{ .{ .vreg = 1 }, .{ .imm = 0 }, .{ .imm = 0 }, .{ .imm = 0 } },
            .arg_count = 1,
            .dst = .{ .vreg = 17 },
        } });

        // Sum vreg1..vreg16 (all live across the call) + vreg17 (call result)
        try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = 18 }, .src = .{ .vreg = 1 } } });
        for (2..17) |i| {
            try b.instrs.append(.{ .add = .{ .dst = .{ .vreg = 18 }, .src = .{ .vreg = @intCast(i) } } });
        }
        try b.instrs.append(.{ .add = .{ .dst = .{ .vreg = 18 }, .src = .{ .vreg = 17 } } });
        try b.instrs.append(.{ .ret = .{ .val = .{ .vreg = 18 } } });
        try mfuncs.append(main_func);
    }

    // sum(1..16) + (1+7) = 136 + 8 = 144
    return .{ mfuncs, 144 };
}

fn testCpuCallSpill(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testCpuCallSpill (16 vars + call) ---\n");

    const result = try buildCallSpillFunc(alloc);
    const mfuncs = result.@"0";
    const expected = result.@"1";

    var emit = try mir_x64.emitModule(mfuncs.items);
    defer emit.code.deinit();

    const code_bytes = emit.code.items;
    try stdout.print("  {d} bytes, entry @ {d}:\n", .{ code_bytes.len, emit.entry_offset });

    const w = std.os.windows;
    const mem = try w.VirtualAlloc(null, code_bytes.len, w.MEM_COMMIT | w.MEM_RESERVE, w.PAGE_EXECUTE_READWRITE);
    defer _ = w.VirtualFree(mem, 0, w.MEM_RELEASE);
    @memcpy(@as([*]u8, @ptrCast(mem))[0..code_bytes.len], code_bytes);

    const entry_ptr = @as([*]u8, @ptrCast(mem)) + emit.entry_offset;
    const func: *const fn () callconv(.C) i64 = @ptrCast(@alignCast(entry_ptr));
    const actual = func();
    try stdout.print("  result: {d} (expected {d})\n", .{ actual, expected });
    try std.testing.expectEqual(expected, actual);
    try stdout.print("  OK\n", .{});
}
