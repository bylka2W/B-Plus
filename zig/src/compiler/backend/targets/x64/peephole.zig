

const std = @import("std");
const mir = @import("../../mir/mir.zig");


pub fn eliminateRedundantMovs(mfunc: *mir.MFunction) void {
    for (mfunc.blocks.items) |*block| {
        var i: usize = 0;
        while (i < block.instrs.items.len) {
            const inst = block.instrs.items[i];
            if (inst == .mov) {
                if (std.meta.eql(inst.mov.dst, inst.mov.src)) {
                    _ = block.instrs.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }
}


pub fn foldMovAdd(mfunc: *mir.MFunction) void {
    for (mfunc.blocks.items) |*block| {
        var i: usize = 0;
        while (i + 1 < block.instrs.items.len) {
            const first = block.instrs.items[i];
            const second = block.instrs.items[i + 1];
            if (first == .mov and second == .add) {
                const dst1 = first.mov.dst;
                const dst2 = second.add.dst;
                if (std.meta.eql(dst1, dst2) and first.mov.src == .imm and second.add.src == .imm) {
                    block.instrs.items[i] = .{ .mov = .{
                        .dst = dst1,
                        .src = .{ .imm = first.mov.src.imm + second.add.src.imm },
                    }};
                    _ = block.instrs.orderedRemove(i + 1);
                }
            }
            i += 1;
        }
    }
}
