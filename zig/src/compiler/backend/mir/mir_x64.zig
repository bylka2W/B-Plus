pub const lowering = @import("../targets/x64/lowering/lower.zig");

pub const EmitResult = lowering.EmitResult;
pub const EmitCodeResult = lowering.EmitCodeResult;
pub const emitModule = lowering.emitModule;
pub const emitCode = lowering.emitCode;
pub const emitSingleFunction = lowering.emitSingleFunction;
pub const iselFunction = lowering.iselFunction;
pub const ir = @import("../targets/x64/ir/inst.zig");
