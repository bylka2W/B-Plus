pub const core = @import("core/machine.zig");
pub const MFunction = core.MFunction;
pub const MModule = core.MModule;
pub const VRegInfo = core.VRegInfo;

pub const instruction = @import("core/instruction.zig");
pub const MInst = instruction.MInst;

pub const operand = @import("core/operand.zig");
pub const MOperand = operand.MOperand;
pub const CondCode = operand.CondCode;

pub const value = @import("core/value.zig");
pub const RegClass = value.RegClass;
pub const DataType = value.DataType;

pub const block = @import("core/block.zig");
pub const MBlock = block.MBlock;

pub const mir_lower = @import("lowering/mir_lower.zig");
pub const verify = @import("passes/verify.zig");
