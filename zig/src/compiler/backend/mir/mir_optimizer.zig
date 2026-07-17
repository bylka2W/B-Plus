const std = @import("std");
const mir = @import("mir.zig");
const mir_dce = @import("mir_dce.zig");
const mir_peephole = @import("mir_peephole.zig");

pub fn optimize(mfunc: *mir.MFunction) !void {
    for (0..3) |_| {
        try mir_dce.dce(mfunc);
        try mir_peephole.optimize(mfunc);
    }
    try mir_dce.dce(mfunc);
}
