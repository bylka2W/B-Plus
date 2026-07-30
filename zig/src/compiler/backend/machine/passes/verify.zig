const std = @import("std");
const machine = @import("../machine.zig");
const operands = @import("verify/operands.zig");
const vregs = @import("verify/vregs.zig");
const cfg = @import("verify/cfg.zig");

pub const VerifyError = operands.VerifyError || vregs.VerifyError || cfg.VerifyError || error{OutOfMemory};

pub fn verifyModule(mod: *const machine.MModule) !void {
    for (mod.functions.items) |*func| {
        try verifyFunction(func);
    }
}

pub fn verifyFunction(func: *const machine.MFunction) VerifyError!void {
    try cfg.verifyCFG(func);

    var defined = std.AutoHashMap(u32, void).init(func.allocator);
    defer defined.deinit();

    // Function parameters are defined at entry
    for (func.params) |p| {
        if (p == .vreg) {
            defined.put(p.vreg.id, {}) catch {};
        }
    }

    for (func.blocks.items) |*blk| {
        for (blk.instrs.items) |inst| {
            if (instruction.dstVReg(inst)) |dst_id| {
                try defined.put(dst_id, {});
            }
            try operands.verifyInst(inst, func, &defined);
        }
    }

    try vregs.checkDefUse(func);
}

const instruction = @import("../core/instruction.zig");
