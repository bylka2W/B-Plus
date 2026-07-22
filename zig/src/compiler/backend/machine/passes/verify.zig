const std = @import("std");
const machine = @import("../machine.zig");

pub fn verifyModule(mod: *const machine.MModule) !void {
    for (mod.functions.items) |*func| {
        try verifyFunction(func);
    }
}

pub fn verifyFunction(func: *const machine.MFunction) !void {
    for (func.blocks.items) |*blk| {
        for (blk.instrs.items) |inst| {
            _ = inst;
        }
    }
}
