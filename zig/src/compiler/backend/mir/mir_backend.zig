pub const mir = @import("mir.zig");
pub const mir_verify = @import("passes/verify.zig");
pub const mir_optimizer = @import("passes/manager.zig");
pub const mir_peephole = @import("passes/cleanup/peephole.zig");
pub const mir_dce = @import("passes/cleanup/dce.zig");
pub const mir_x64 = @import("mir_x64.zig");
pub const mir_ssa_destroy = @import("passes/ssa/ssa_destroy.zig");
pub const mir_copy_prop = @import("passes/cleanup/copy_prop.zig");
