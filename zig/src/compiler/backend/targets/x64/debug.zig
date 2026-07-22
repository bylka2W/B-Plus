/// Debug and trace utilities for x64 backend.
const std = @import("std");
const mir = @import("../../mir/mir.zig");
const regalloc = @import("../../regalloc/regalloc.zig");
const regs = @import("registers.zig");

/// Dump MIR instructions for a block (debug helper).
pub fn dumpBlock(stdout: anytype, mfunc: *const mir.MFunction, block_idx: usize, block: *const mir.MBlock, ra: *const regalloc.RegAllocResult) void {
    stdout.print("  [EMIT] function '{s}' block b{d} '{s}':\n", .{ mfunc.name, block_idx, block.label });
    for (block.instrs.items, 0..) |inst, ii| {
        stdout.print("    {d}: ", .{ii});
        switch (inst) {
            .cmp => |c| stdout.print("cmp {s} v{d}, v{d}, v{d}", .{
                @tagName(c.cc),
                switch (c.dst) { .vreg => |v| v, else => 0 },
                switch (c.a) { .vreg => |v| v, else => 0 },
                switch (c.b) { .vreg => |v| v, else => 0 },
            }),
            .cmp_flags => |cf| {
                const a_reg: i16 = regalloc.regForOp(ra, cf.a);
                const b_reg: i16 = regalloc.regForOp(ra, cf.b);
                stdout.print("cmp_flags (vreg {d}->r{d}, vreg {d}->r{d})", .{
                    switch (cf.a) { .vreg => |v| v, else => 0 }, a_reg,
                    switch (cf.b) { .vreg => |v| v, else => 0 }, b_reg,
                });
            },
            .jcc => |j| stdout.print("jcc {s} b{d}", .{ @tagName(j.cc), j.target }),
            .jmp => |j| stdout.print("jmp b{d}", .{j.target}),
            else => stdout.print("({s})", .{@tagName(inst)}),
        }
        stdout.print("\n", .{});
    }
}

/// Dump all blocks in a function (for functions with backedges).
pub fn dumpFunction(stdout: anytype, mfunc: *const mir.MFunction) void {
    stdout.print("  [EMIT_DUMP] function '{s}':\n", .{mfunc.name});
    for (mfunc.blocks.items, 0..) |*blk, bi| {
        stdout.print("    b{d} '{s}':\n", .{ bi, blk.label });
        for (blk.instrs.items, 0..) |mi, ii| {
            stdout.print("      {d}: ", .{ii});
            if (mi == .mov) {
                const d = mi.mov.dst;
                stdout.print("mov v{d} ...", .{if (d == .vreg) d.vreg else 0});
            } else if (mi == .add) {
                const d = mi.add.dst;
                stdout.print("add v{d} ...", .{if (d == .vreg) d.vreg else 0});
            } else if (mi == .cmp_flags) {
                const a = if (mi.cmp_flags.a == .vreg) mi.cmp_flags.a.vreg else 0;
                const b = if (mi.cmp_flags.b == .vreg) mi.cmp_flags.b.vreg else 0;
                stdout.print("cmp_flags v{d}, v{d}", .{a, b});
                if (a == 0 or b == 0) stdout.print(" \xe2\x86\x90 BOGUS VREG 0!", .{});
            } else if (mi == .jmp) {
                stdout.print("jmp b{d}", .{mi.jmp.target});
            } else if (mi == .jcc) {
                stdout.print("jcc {s} b{d}", .{ @tagName(mi.jcc.cc), mi.jcc.target });
            } else if (mi == .ret) {
                const v = if (mi.ret.val == .vreg) mi.ret.val.vreg else 0;
                stdout.print("ret v{d}", .{v});
            } else if (mi == .phi) {
                stdout.print("phi", .{});
            } else {
                stdout.print("({s})", .{@tagName(mi)});
            }
            stdout.print("\n", .{});
        }
    }
}

/// Check if a function has back-edges (loops).
pub fn hasBackEdges(mfunc: *const mir.MFunction) bool {
    for (mfunc.blocks.items, 0..) |*b, bi| {
        if (b.instrs.items.len == 0) continue;
        const last = b.instrs.items[b.instrs.items.len - 1];
        switch (last) {
            .jcc => |j| { if (j.target <= bi) return true; },
            .jmp => |j| { if (j.target <= bi) return true; },
            else => {},
        }
    }
    return false;
}
