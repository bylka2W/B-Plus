// ─── MIR core: target-independent types ───

pub const operand = @import("operand.zig");
pub const opcode = @import("opcode.zig");
pub const value = @import("value.zig");
pub const function = @import("function.zig");

pub const PhysReg = operand.PhysReg;
pub const MOperand = operand.MOperand;
pub const MemOp = operand.MemOp;
pub const CondCode = operand.CondCode;

pub const DataType = value.DataType;
pub const VRegClass = value.VRegClass;
pub const VRegInfo = value.VRegInfo;

pub const MovInst = opcode.MovInst;
pub const AddInst = opcode.AddInst;
pub const SubInst = opcode.SubInst;
pub const IMulInst = opcode.IMulInst;
pub const IDivInst = opcode.IDivInst;
pub const AndInst = opcode.AndInst;
pub const OrInst = opcode.OrInst;
pub const XorInst = opcode.XorInst;
pub const ShiftInst = opcode.ShiftInst;
pub const UnaryInst = opcode.UnaryInst;
pub const FloatBinOp = opcode.FloatBinOp;
pub const FCmpInst = opcode.FCmpInst;
pub const ConvInst = opcode.ConvInst;
pub const SelectInst = opcode.SelectInst;
pub const TestFlagsInst = opcode.TestFlagsInst;
pub const CmpInst = opcode.CmpInst;
pub const CmpFlagsInst = opcode.CmpFlagsInst;
pub const JmpInst = opcode.JmpInst;
pub const JccInst = opcode.JccInst;
pub const CallInst = opcode.CallInst;
pub const AllocaInst = opcode.AllocaInst;
pub const LoadInst = opcode.LoadInst;
pub const StoreInst = opcode.StoreInst;
pub const LeaInst = opcode.LeaInst;
pub const RetInst = opcode.RetInst;
pub const PhiIncoming = opcode.PhiIncoming;
pub const PhiInst = opcode.PhiInst;
pub const MInst = opcode.MInst;
pub const MInstUtils = opcode.MInstUtils;

pub const MBlock = function.MBlock;
pub const MFunction = function.MFunction;
