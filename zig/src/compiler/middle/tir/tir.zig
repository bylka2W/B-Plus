pub const types = @import("types.zig");
pub const lower = @import("lower.zig");

pub const TypeId = types.TypeId;
pub const ValueId = types.ValueId;
pub const BlockId = types.BlockId;
pub const FuncId = types.FuncId;
pub const NO_VALUE = types.NO_VALUE;
pub const INVALID_TYPE = types.INVALID_TYPE;

pub const Op = types.Op;
pub const TypeTable = types.TypeTable;
pub const Function = types.Function;
pub const Module = types.Module;
pub const Instruction = types.Instruction;

pub const lowerModule = lower.lowerModule;
