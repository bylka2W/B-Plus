/// Legacy wrapper — x64 lowering now lives in targets/x64/lowering/lower.zig.
pub const lowering = @import("../targets/x64/lowering/lower.zig");

pub const EmitResult = lowering.EmitResult;
pub const EmitCodeResult = lowering.EmitCodeResult;
pub const emitModule = lowering.emitModule;
pub const emitCode = lowering.emitCode;
pub const emitSingleFunction = lowering.emitSingleFunction;
