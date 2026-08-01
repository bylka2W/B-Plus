const std = @import("std");
const mir = @import("../mir.zig");
const mir_dce = @import("cleanup/dce.zig");
const mir_peephole = @import("cleanup/peephole.zig");
const mir_ssa_destroy = @import("ssa/ssa_destroy.zig");
const mir_copy_prop = @import("cleanup/copy_prop.zig");
const mir_verify = @import("verify.zig");
const mir_addr_fold = @import("memory/addr_fold.zig");

fn hasBackedge(mfunc: *const mir.MFunction) bool {
    for (mfunc.blocks.items, 0..) |*block, bi| {
        if (block.instrs.items.len == 0) continue;
        const last = block.instrs.items[block.instrs.items.len - 1];
        switch (last) {
            .jcc => |j| { if (j.target <= bi) return true; },
            .jmp => |j| { if (j.target <= bi) return true; },
            else => {},
        }
    }
    return false;
}

fn dumpMIR(mfunc: *const mir.MFunction, label: []const u8) void {
    std.debug.print("\n  [DUMP] {s} - function '{s}':\n", .{ label, mfunc.name });
    for (mfunc.blocks.items, 0..) |block, bi| {
        std.debug.print("    b{d} '{s}':\n", .{ bi, block.label });
        for (block.instrs.items, 0..) |inst, ii| {
            std.debug.print("      {d}: ", .{ii});
            dumpInst(inst);
            std.debug.print("\n", .{});
        }
    }
}

fn dumpInst(inst: mir.MInst) void {
    switch (inst) {
        .mov => |m| { std.debug.print("mov ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.src); },
        .add => |m| { std.debug.print("add ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.src); },
        .sub => |m| { std.debug.print("sub ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.src); },
        .imul => |m| { std.debug.print("imul ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.src); },
        .@"and" => |m| { std.debug.print("and ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.src); },
        .@"or" => |m| { std.debug.print("or ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.src); },
        .xor => |m| { std.debug.print("xor ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.src); },
        .cmp_flags => |cf| { std.debug.print("cmp_flags ", .{}); dumpOp(cf.a); std.debug.print(", ", .{}); dumpOp(cf.b); },
        .cmp => |c| { std.debug.print("cmp {s} ", .{@tagName(c.cc)}); dumpOp(c.a); std.debug.print(", ", .{}); dumpOp(c.b); },
        .jmp => |j| std.debug.print("jmp b{d}", .{j.target}),
        .jcc => |j| std.debug.print("jcc {s} b{d}", .{ @tagName(j.cc), j.target }),
        .trap => std.debug.print("trap", .{}),
        .lea => |l| {
            std.debug.print("lea ", .{}); dumpOp(l.dst);
            std.debug.print(", [", .{}); dumpOp(l.base);
            if (l.index != .imm) { std.debug.print(" + ", .{}); dumpOp(l.index); }
            std.debug.print(" * {d} + {d}]", .{ l.scale, l.disp });
        },
        .ret => |r| {
            switch (r) {
                .void_ret => std.debug.print("ret void", .{}),
                .value => |v| { std.debug.print("ret ", .{}); dumpOp(v); },
            }
        },
        .alloca => |a| { std.debug.print("alloca ", .{}); dumpOp(a.dst); },
        .load => |l| { std.debug.print("load ", .{}); dumpOp(l.dst); std.debug.print(", ", .{}); dumpOp(l.ptr); },
        .store => |s| { std.debug.print("store ", .{}); dumpOp(s.ptr); std.debug.print(", ", .{}); dumpOp(s.src); },
        .not_op => |n| { std.debug.print("not ", .{}); dumpOp(n.dst); },
        .neg_op => |n| { std.debug.print("neg ", .{}); dumpOp(n.dst); },
        .shl => |s| { std.debug.print("shl ", .{}); dumpOp(s.dst); std.debug.print(", ", .{}); dumpOp(s.amount); },
        .shr => |s| { std.debug.print("shr ", .{}); dumpOp(s.dst); std.debug.print(", ", .{}); dumpOp(s.amount); },
        .sar => |s| { std.debug.print("sar ", .{}); dumpOp(s.dst); std.debug.print(", ", .{}); dumpOp(s.amount); },
        .select => |s| { std.debug.print("select ", .{}); dumpOp(s.dst); std.debug.print(", cc={s}", .{@tagName(s.cc)}); },
        .phi => |_| { std.debug.print("phi", .{}); },
        .test_flags => |tf| { std.debug.print("test_flags ", .{}); dumpOp(tf.a); std.debug.print(", ", .{}); dumpOp(tf.b); },
        .setcc => |s| { std.debug.print("setcc ", .{}); dumpOp(s.dst); std.debug.print(", cc={s}", .{@tagName(s.cc)}); },
        .call => |c| { std.debug.print("call {s}", .{c.name}); },
        .sext_op => |c| { std.debug.print("sext ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.src); },
        .zext_op => |c| { std.debug.print("zext ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.src); },
        .trunc_op => |c| { std.debug.print("trunc ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.src); },
        .fadd => |f| { std.debug.print("fadd ", .{}); dumpOp(f.dst); std.debug.print(", ", .{}); dumpOp(f.a); std.debug.print(", ", .{}); dumpOp(f.b); },
        .fsub => |f| { std.debug.print("fsub ", .{}); dumpOp(f.dst); std.debug.print(", ", .{}); dumpOp(f.a); std.debug.print(", ", .{}); dumpOp(f.b); },
        .fmul => |f| { std.debug.print("fmul ", .{}); dumpOp(f.dst); std.debug.print(", ", .{}); dumpOp(f.a); std.debug.print(", ", .{}); dumpOp(f.b); },
        .fdiv => |f| { std.debug.print("fdiv ", .{}); dumpOp(f.dst); std.debug.print(", ", .{}); dumpOp(f.a); std.debug.print(", ", .{}); dumpOp(f.b); },
        .fneg_op => |n| { std.debug.print("fneg ", .{}); dumpOp(n.dst); },
        .fsqrt_op => |n| { std.debug.print("fsqrt ", .{}); dumpOp(n.dst); },
        .fcmp => |c| { std.debug.print("fcmp ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.a); std.debug.print(", ", .{}); dumpOp(c.b); },
        .sitofp => |c| { std.debug.print("sitofp ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.src); },
        .fptosi => |c| { std.debug.print("fptosi ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.src); },
        .fpext => |c| { std.debug.print("fpext ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.src); },
        .fptrunc => |c| { std.debug.print("fptrunc ", .{}); dumpOp(c.dst); std.debug.print(", ", .{}); dumpOp(c.src); },
        .idiv => |m| { std.debug.print("idiv ", .{}); dumpOp(m.quotient); std.debug.print(", ", .{}); dumpOp(m.divisor); },
        .state_init => |m| { std.debug.print("state_init ", .{}); dumpOp(m.initial_state); },
        .state_enter => |m| { std.debug.print("state_enter ", .{}); dumpOp(m.state_id); },
        .state_exit => |m| { std.debug.print("state_exit ", .{}); dumpOp(m.state_id); },
        .event_dispatch => |m| { std.debug.print("event_dispatch ", .{}); dumpOp(m.dst); std.debug.print(", ", .{}); dumpOp(m.buf); std.debug.print(", ", .{}); dumpOp(m.size); },
        .transition_check => |m| { std.debug.print("transition_check ", .{}); dumpOp(m.event); std.debug.print(" ev={d}", .{m.event_id}); },
        .guard_eval => |m| { std.debug.print("guard_eval ", .{}); dumpOp(m.lhs); std.debug.print(", ", .{}); dumpOp(m.rhs); std.debug.print(" cc={s}", .{@tagName(m.cc)}); },
        .string_const => |s| { std.debug.print("string_const ", .{}); dumpOp(s.dst); std.debug.print(", \"{s}\"", .{s.data}); },
    }
}

fn dumpOp(op: mir.MOperand) void {
    switch (op) {
        .vreg => |v| std.debug.print("v{d}", .{v}),
        .imm => |v| std.debug.print("#{d}", .{v}),
        .phys => |r| {
            const names = [_][]const u8{ "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
            const idx: usize = @intCast(r);
            if (idx < names.len) std.debug.print("{s}", .{names[idx]}) else std.debug.print("phys({d})", .{idx});
        },
        .mem => |m| {
            std.debug.print("[", .{});
            const names = [_][]const u8{ "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
            const idx: usize = @intCast(m.base);
            if (idx < names.len) std.debug.print("{s}", .{names[idx]}) else std.debug.print("phys({d})", .{idx});
            std.debug.print("+{d}]", .{m.offset});
        },
    }
}

pub fn optimize(mfunc: *mir.MFunction) !void {
    const debug = blk: {
        const val = std.process.getEnvVarOwned(mfunc.allocator, "BPC_DEBUG") catch { break :blk false; };
        defer mfunc.allocator.free(val);
        break :blk hasBackedge(mfunc) and val.len > 0;
    };

    try mir_ssa_destroy.destroySSA(mfunc);
    try mir_verify.verifyNoPhis(mfunc);
    mir_verify.verifyMir(mfunc) catch |err| {
        if (err == error.UnreachableBlock) dumpMIR(mfunc, "AFTER destroySSA UNREACHABLE");
        return err;
    };
    if (debug) dumpMIR(mfunc, "after SSA destroy");

    try mir_addr_fold.AddrFoldPass.run(mfunc);
    try mir_verify.verifyMir(mfunc);
    if (debug) dumpMIR(mfunc, "after addr_fold");

    try mir_copy_prop.propagateCopies(mfunc);
    if (debug) dumpMIR(mfunc, "after copy_prop #1");

    for (0..3) |_| {
        try mir_dce.dce(mfunc);
        try mir_peephole.optimize(mfunc);
        try mir_copy_prop.propagateCopies(mfunc);
    }
    try mir_dce.dce(mfunc);
    if (debug) dumpMIR(mfunc, "FINAL");
}
