/// ─── MIR public API ───
///
/// Target-independent machine IR (MIR) layer.
/// Core types live in `core/`, target-specific backends in `targets/`.
///
/// Usage:
///   const mir = @import("mir.zig");
///   var func = mir.MFunction.init(alloc, "foo");
///   func.blocks.append(.{ .label = "entry", .instrs = ... });

pub const core = @import("core/mir.zig");

pub const PhysReg = core.PhysReg;
pub const MOperand = core.MOperand;
pub const MemOp = core.MemOp;
pub const CondCode = core.CondCode;

pub const DataType = core.DataType;
pub const VRegClass = core.VRegClass;
pub const VRegInfo = core.VRegInfo;

pub const MovInst = core.MovInst;
pub const AddInst = core.AddInst;
pub const SubInst = core.SubInst;
pub const IMulInst = core.IMulInst;
pub const IDivInst = core.IDivInst;
pub const AndInst = core.AndInst;
pub const OrInst = core.OrInst;
pub const XorInst = core.XorInst;
pub const ShiftInst = core.ShiftInst;
pub const UnaryInst = core.UnaryInst;
pub const FloatBinOp = core.FloatBinOp;
pub const FCmpInst = core.FCmpInst;
pub const ConvInst = core.ConvInst;
pub const SelectInst = core.SelectInst;
pub const TestFlagsInst = core.TestFlagsInst;
pub const CmpInst = core.CmpInst;
pub const CmpFlagsInst = core.CmpFlagsInst;
pub const JmpInst = core.JmpInst;
pub const JccInst = core.JccInst;
pub const CallInst = core.CallInst;
pub const AllocaInst = core.AllocaInst;
pub const LoadInst = core.LoadInst;
pub const StoreInst = core.StoreInst;
pub const LeaInst = core.LeaInst;
pub const RetInst = core.RetInst;
pub const PhiIncoming = core.PhiIncoming;
pub const PhiInst = core.PhiInst;
pub const MInst = core.MInst;
pub const MInstUtils = core.MInstUtils;

pub const MBlock = core.MBlock;
pub const MFunction = core.MFunction;

/// ─── Target API ───
pub const target = struct {
    pub const Target = @import("../targets/common/target.zig").Target;
    pub const TargetContext = @import("../targets/common/target.zig").TargetContext;
    pub const RegAllocResult = @import("../targets/common/target.zig").RegAllocResult;
    pub const SpillSlot = @import("../targets/common/target.zig").SpillSlot;
};
