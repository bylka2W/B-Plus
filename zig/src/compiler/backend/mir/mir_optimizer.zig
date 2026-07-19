const std = @import("std");
const mir = @import("mir.zig");
const mir_dce = @import("mir_dce.zig");
const mir_peephole = @import("mir_peephole.zig");
const mir_ssa_destroy = @import("mir_ssa_destroy.zig");
const mir_copy_prop = @import("mir_copy_prop.zig");
const mir_verify = @import("mir_verify.zig");

pub fn optimize(mfunc: *mir.MFunction) !void {
    try mir_ssa_destroy.destroySSA(mfunc);
    try mir_verify.verifyNoPhis(mfunc);
    try mir_verify.verifyMir(mfunc);

    try mir_copy_prop.propagateCopies(mfunc);

    for (0..3) |_| {
        try mir_dce.dce(mfunc);
        try mir_peephole.optimize(mfunc);
        try mir_copy_prop.propagateCopies(mfunc);
    }
    try mir_dce.dce(mfunc);
}
