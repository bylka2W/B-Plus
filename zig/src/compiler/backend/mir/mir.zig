///публичный API MIR
///
///независимый от конкретной платформы слой машинного IR.
///основные типы находятся в `core/`, а код для конкретных платформ — в `targets/`.
///
///юзать как 
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
pub const SetCCInst = core.SetCCInst;
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
pub const MemSize = core.MemSize;
pub const MInst = core.MInst;
pub const MInstUtils = core.MInstUtils;

pub const StateInitInst = core.StateInitInst;
pub const StateEnterInst = core.StateEnterInst;
pub const StateExitInst = core.StateExitInst;
pub const EventDispatchInst = core.EventDispatchInst;
pub const TransitionCheckInst = core.TransitionCheckInst;
pub const GuardEvalInst = core.GuardEvalInst;

pub const MBlock = core.MBlock;
pub const MFunction = core.MFunction;
pub const MModule = core.MModule;

///проходы компилятора
pub const passes = struct {
    pub const ssa_destroy = @import("passes/ssa/ssa_destroy.zig");
    pub const dce = @import("passes/cleanup/dce.zig");
    pub const copy_prop = @import("passes/cleanup/copy_prop.zig");
    pub const peephole = @import("passes/cleanup/peephole.zig");
    pub const addr_fold = @import("passes/memory/addr_fold.zig");
    pub const verify = @import("passes/verify.zig");
    pub const manager = @import("passes/manager.zig");
};

///API платформы
pub const target = struct {
    pub const Target = @import("../targets/common/target.zig").Target;
    pub const TargetContext = @import("../targets/common/target.zig").TargetContext;
    pub const RegAllocResult = @import("../targets/common/target.zig").RegAllocResult;
    pub const SpillSlot = @import("../targets/common/target.zig").SpillSlot;
};
