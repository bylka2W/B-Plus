/// старое говно wrapper теперь x64 lowering находится в targets/x64/lowering.ring/lower.zig.
pub const lowering = @import("../targets/x64/lowering/lower.zig");

pub const EmitResult = lowering.EmitResult;
pub const EmitCodeResult = lowering.EmitCodeResult;
pub const emitModule = lowering.emitModule;
pub const emitCode = lowering.emitCode;
pub const emitSingleFunction = lowering.emitSingleFunction;
