const std = @import("std");
const mir = @import("../../src/compiler/backend/mir/mir.zig");
const mir_x64 = @import("../../src/compiler/backend/mir/mir_x64.zig");

fn dumpMIR(writer: anytype, mfunc: *const mir.MFunction, num_vregs: u32) !void {
    try writer.print("  MIR ({d} blocks, {d} vregs):\n", .{ mfunc.blocks.items.len, num_vregs });
    for (mfunc.blocks.items, 0..) |*block, bi| {
        try writer.print("    b{d}:\n", .{bi});
        for (block.instrs.items, 0..) |inst, ii| {
            try writer.print("      {d}: ", .{ii});
            switch (inst) {
                .mov => |m| {
                    try writer.print("mov v{d}, ", .{m.dst.vreg});
                    try dumpOp(writer, m.src);
                },
                .add => |m| {
                    try writer.print("add v{d}, ", .{m.dst.vreg});
                    try dumpOp(writer, m.src);
                },
                .sub => |m| {
                    try writer.print("sub v{d}, ", .{m.dst.vreg});
                    try dumpOp(writer, m.src);
                },
                .imul => |m| {
                    try writer.print("imul v{d}, ", .{m.dst.vreg});
                    try dumpOp(writer, m.src);
                },
                .idiv => |m| {
                    try writer.print("idiv v{d}, ", .{m.dst.vreg});
                    try dumpOp(writer, m.src);
                },
                .cmp => |m| try writer.print("cmp {s} v{d}, v{d}, v{d}", .{ @tagName(m.cc), m.dst.vreg, m.a.vreg, m.b.vreg }),
                .cmp_flags => |m| try writer.print("cmp_flags v{d}, v{d}", .{ m.a.vreg, m.b.vreg }),
                .jmp => |m| try writer.print("jmp b{d}", .{m.target}),
                .jcc => |m| try writer.print("jcc {s} b{d}", .{ @tagName(m.cc), m.target }),
                .load => |m| try writer.print("load v{d}, v{d}", .{ m.dst.vreg, m.ptr.vreg }),
                .store => |m| try writer.print("store v{d}, v{d}", .{ m.src.vreg, m.ptr.vreg }),
                .call => |m| try writer.print("call v{d}", .{m.dst.vreg}),
                .alloca => |m| try writer.print("alloca v{d}", .{m.dst.vreg}),
                .ret => |m| {
                    try writer.print("ret ", .{});
                    try dumpOp(writer, m.val);
                },
            }
            try writer.print("\n", .{});
        }
    }
}

fn dumpOp(writer: anytype, op: mir.MOperand) !void {
    switch (op) {
        .vreg => |v| try writer.print("v{d}", .{v}),
        .imm => |v| try writer.print("{d}", .{v}),
        .phys => |v| try writer.print("phys({d})", .{@intFromEnum(v)}),
        .mem => |m| try writer.print("mem({s}+{d})", .{@tagName(m.base), m.offset}),
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    var rnd = std.Random.DefaultPrng.init(42);
    const rand = rnd.random();

    var passed: u64 = 0;
    var failed: u64 = 0;

    const num_tests = 100_000;
    try stdout.print("Running {d} random MIR programs...\n", .{num_tests});

    var max_bytes: usize = 0;
    var test_i: u64 = 0;
    while (test_i < num_tests) : (test_i += 1) {
        var result = generateRandomMIR(alloc, rand) catch |err| {
            try stdout.print("\n  [{d}] generate failed: {}\n", .{ test_i, err });
            failed += 1;
            continue;
        };
        defer result.deinit();

        const expected = interpretMFunction(&result.mfunc) catch |err| {
            try stdout.print("\n  [{d}] interpret failed: {}\n", .{ test_i, err });
            failed += 1;
            continue;
        };

        const compile_result = mir_x64.emitModule(&[_]mir.MFunction{result.mfunc}) catch |err| {
            try stdout.print("\n  [{d}] compile failed: {}\n", .{ test_i, err });
            failed += 1;
            continue;
        };
        defer compile_result.code.deinit();

        const actual = executeCode(compile_result.code.items);
        if (actual != expected) {
            try stdout.print("\n  [{d}] MISMATCH: expected {d}, got {d}\n", .{ test_i, expected, actual });
            if (failed < 3) try dumpMIR(stdout, &result.mfunc, result.vreg_count);
            failed += 1;
        } else {
            passed += 1;
        }

        if (compile_result.code.items.len > max_bytes) {
            max_bytes = compile_result.code.items.len;
        }

        if (test_i % 10_000 == 9999) {
            try stdout.print("  {d}/{d} passed, max code size: {d} bytes\n", .{ passed, test_i + 1, max_bytes });
        }
    }

    try stdout.print("\n{d}/{d} passed, {d} failed, max code size: {d} bytes\n", .{ passed, num_tests, failed, max_bytes });
    if (failed > 0) return error.FuzzTestsFailed;
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

const FuzzResult = struct {
    mfunc: mir.MFunction,
    vreg_count: u32,

    fn deinit(self: *FuzzResult) void {
        self.mfunc.deinit();
    }
};

fn generateRandomMIR(alloc: std.mem.Allocator, rand: std.Random) !FuzzResult {
    const num_vregs: u32 = rand.intRangeAtMost(u32, 2, 20);
    const num_body_instrs: usize = rand.intRangeAtMost(usize, 0, 40);
    const num_blocks: usize = if (rand.boolean()) 1 else rand.intRangeAtMost(usize, 2, 5);

    var mfunc = mir.MFunction.init(alloc, "main");
    errdefer mfunc.deinit();

    // Create all blocks
    var i: usize = 0;
    while (i < num_blocks) : (i += 1) {
        const label = try std.fmt.allocPrint(alloc, "b{d}", .{i});
        try mfunc.blocks.append(.{
            .label = label,
            .instrs = std.ArrayList(mir.MInst).init(alloc),
        });
    }

    // Block 0 preamble: define all vregs as mov vN, 0
    {
        const b = &mfunc.blocks.items[0];
        var v: u32 = 1;
        while (v <= num_vregs) : (v += 1) {
            try b.instrs.append(.{ .mov = .{ .dst = .{ .vreg = v }, .src = .{ .imm = 0 } } });
        }
    }

    // Distribute body instructions across blocks (excluding preamble and terminators)
    var remaining = num_body_instrs;
    for (mfunc.blocks.items, 0..) |*block, bi| {
        if (remaining == 0) break;
        const max_here = remaining / (num_blocks - bi);
        const n = if (max_here > 0) rand.intRangeAtMost(usize, 0, max_here) else 0;
        remaining -= n;

        var j: usize = 0;
        while (j < n) : (j += 1) {
            const inst = randomBodyInst(rand, num_vregs) catch {
                try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = randomVReg(rand, num_vregs) }, .src = randomMOperand(rand, num_vregs) } });
                continue;
            };
            try block.instrs.append(inst);
        }
    }

    // Add terminators
    for (mfunc.blocks.items, 0..) |*block, bi| {
        const is_last = bi == mfunc.blocks.items.len - 1;
        // Only add terminator if the block doesn't already have one
        if (block.instrs.items.len > 0) {
            const last = block.instrs.items[block.instrs.items.len - 1];
            if (last == .ret or last == .jmp or last == .jcc) continue;
        }

        if (is_last) {
            try block.instrs.append(.{ .ret = .{ .val = randomMOperand(rand, num_vregs) } });
        } else {
            // Random chance for a conditional jump, otherwise unconditional
            if (rand.boolean()) {
                // Simple unconditional forward jump
                try block.instrs.append(.{ .jmp = .{ .target = bi + 1 } });
            } else {
                // cmp_flags + jcc (conditional) + jmp (fallthrough to next)
                const av = randomVReg(rand, num_vregs);
                const bv = randomVReg(rand, num_vregs);
                try block.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = av }, .b = .{ .vreg = bv } } });
                const jcc_target = rand.intRangeAtMost(usize, bi + 1, num_blocks - 1);
                try block.instrs.append(.{ .jcc = .{ .cc = .lt, .target = jcc_target } });
                try block.instrs.append(.{ .jmp = .{ .target = bi + 1 } });
            }
        }
    }

    return .{ .mfunc = mfunc, .vreg_count = num_vregs };
}

fn randomBodyInst(rand: std.Random, num_vregs: u32) !mir.MInst {
    const tag = rand.intRangeAtMost(u8, 0, 6);
    return switch (tag) {
        0 => .{ .mov = .{ .dst = .{ .vreg = randomVReg(rand, num_vregs) }, .src = randomMOperand(rand, num_vregs) } },
        1 => .{ .add = .{ .dst = .{ .vreg = randomVReg(rand, num_vregs) }, .src = randomMOperand(rand, num_vregs) } },
        2 => .{ .sub = .{ .dst = .{ .vreg = randomVReg(rand, num_vregs) }, .src = randomMOperand(rand, num_vregs) } },
        3 => .{ .imul = .{ .dst = .{ .vreg = randomVReg(rand, num_vregs) }, .src = randomMOperand(rand, num_vregs) } },
        4 => .{ .idiv = .{ .dst = .{ .vreg = randomVReg(rand, num_vregs) }, .src = .{ .imm = rand.intRangeAtMost(i64, -100, -1) } } },
        5 => .{ .cmp = .{ .cc = .lt, .dst = .{ .vreg = randomVReg(rand, num_vregs) }, .a = .{ .vreg = randomVReg(rand, num_vregs) }, .b = .{ .vreg = randomVReg(rand, num_vregs) } } },
        6 => .{ .cmp_flags = .{ .a = .{ .vreg = randomVReg(rand, num_vregs) }, .b = .{ .vreg = randomVReg(rand, num_vregs) } } },
        else => return error.Retry,
    };
}

fn randomVReg(rand: std.Random, num_vregs: u32) u32 {
    return rand.intRangeAtMost(u32, 1, if (num_vregs > 1) num_vregs else 1);
}

fn randomMOperand(rand: std.Random, num_vregs: u32) mir.MOperand {
    const kind = rand.intRangeAtMost(u8, 0, 3);
    return switch (kind) {
        0, 1, 2 => .{ .vreg = randomVReg(rand, num_vregs) },
        else => .{ .imm = rand.intRangeAtMost(i64, -100, 100) },
    };
}

fn interpretMFunction(mfunc: *const mir.MFunction) !i64 {
    var values = std.AutoHashMap(u32, i64).init(mfunc.allocator);
    defer values.deinit();

    var cmp_a: i64 = 0;
    var cmp_b: i64 = 0;
    var bi: usize = 0;
    var total_ops: u64 = 0;
    const max_ops: u64 = 10_000;

    while (bi < mfunc.blocks.items.len) {
        total_ops += 1;
        if (total_ops > max_ops) return error.TooManyOps;

        const block = &mfunc.blocks.items[bi];
        var did_control = false;

        for (block.instrs.items) |inst| {
            switch (inst) {
                .mov => |m| try setValue(&values, m.dst, try resolveOp(&values, m.src)),
                .add => |m| {
                    const dv = try resolveOp(&values, m.dst);
                    const sv = try resolveOp(&values, m.src);
                    try setValue(&values, m.dst, dv +% sv);
                },
                .sub => |m| {
                    const dv = try resolveOp(&values, m.dst);
                    const sv = try resolveOp(&values, m.src);
                    try setValue(&values, m.dst, dv -% sv);
                },
                .imul => |m| {
                    const dv = try resolveOp(&values, m.dst);
                    const sv = try resolveOp(&values, m.src);
                    try setValue(&values, m.dst, dv *% sv);
                },
                .idiv => |m| {
                    const dv = try resolveOp(&values, m.dst);
                    const sv = try resolveOp(&values, m.src);
                    try setValue(&values, m.dst, @divTrunc(dv, sv));
                },
                .cmp => |m| {
                    const av = try resolveOp(&values, m.a);
                    const bv = try resolveOp(&values, m.b);
                    const r: i64 = switch (m.cc) {
                        .lt => @intFromBool(av < bv),
                        .le => @intFromBool(av <= bv),
                        .gt => @intFromBool(av > bv),
                        .ge => @intFromBool(av >= bv),
                        .eq => @intFromBool(av == bv),
                        .ne => @intFromBool(av != bv),
                    };
                    try setValue(&values, m.dst, r);
                },
                .cmp_flags => |m| {
                    cmp_a = try resolveOp(&values, m.a);
                    cmp_b = try resolveOp(&values, m.b);
                },
                .jmp => |m| {
                    bi = m.target;
                    did_control = true;
                    break;
                },
                .jcc => |m| {
                    const taken: bool = switch (m.cc) {
                        .lt => cmp_a < cmp_b,
                        .le => cmp_a <= cmp_b,
                        .gt => cmp_a > cmp_b,
                        .ge => cmp_a >= cmp_b,
                        .eq => cmp_a == cmp_b,
                        .ne => cmp_a != cmp_b,
                    };
                    if (taken) {
                        bi = m.target;
                    } else {
                        // Fall through: the next instruction in the same block (should be jmp)
                        continue;
                    }
                    did_control = true;
                    break;
                },
                .call => |m| {
                    try setValue(&values, m.dst, 0);
                },
                .alloca => |m| {
                    // Simulated alloca: return a dummy address
                    try setValue(&values, m.dst, 0x1000);
                },
                .load => |m| {
                    // Unsupported in fuzzer, return 0
                    try setValue(&values, m.dst, 0);
                },
                .store => |m| {
                    // Unsupported in fuzzer, no-op
                    _ = m;
                },
                .ret => |m| {
                    return resolveOp(&values, m.val);
                },
            }
        }

        if (!did_control) bi += 1;
    }

    return error.NoReturn;
}

fn resolveOp(values: *std.AutoHashMap(u32, i64), op: mir.MOperand) !i64 {
    return switch (op) {
        .vreg => |v| values.get(v) orelse 0,
        .imm => |v| v,
        .phys => 0,
        .mem => 0,
    };
}

fn setValue(values: *std.AutoHashMap(u32, i64), op: mir.MOperand, val: i64) !void {
    switch (op) {
        .vreg => |v| try values.put(v, val),
        else => {},
    }
}
