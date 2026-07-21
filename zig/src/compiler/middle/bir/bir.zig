const std = @import("std");

// ─── IR submodule imports ───
pub const value = @import("core/value.zig");
pub const types = @import("core/types.zig");
pub const instruction = @import("core/instruction.zig");
pub const block = @import("core/block.zig");
pub const function = @import("core/function.zig");
pub const module = @import("core/module.zig");

// ─── IR namespace (LLVM-style: bir.ir.Module, bir.ir.Type, etc.) ───
pub const ir = struct {
    pub const ValueId = value.ValueId;
    pub const BlockId = value.BlockId;
    pub const FunctionId = value.FunctionId;
    pub const INVALID_ID = value.INVALID_ID;
    pub const NO_VALUE = value.NO_VALUE;
    pub const InstRef = value.InstRef;
    pub const ValueInfo = value.ValueInfo;

    pub const TypeId = types.TypeId;
    pub const INVALID_TYPE = types.INVALID_TYPE;
    pub const ScalarKind = types.ScalarKind;
    pub const AddressSpace = types.AddressSpace;
    pub const Type = types.Type;
    pub const TypeTable = types.TypeTable;

    pub const Op = instruction.Op;
    pub const ConstData = instruction.ConstData;
    pub const PhiIncoming = instruction.PhiIncoming;
    pub const MemoryOrder = instruction.MemoryOrder;
    pub const AtomicOp = instruction.AtomicOp;
    pub const CastKind = instruction.CastKind;
    pub const BarrierKind = instruction.BarrierKind;
    pub const SampleInfo = instruction.SampleInfo;
    pub const GepInfo = instruction.GepInfo;
    pub const CallInfo = instruction.CallInfo;
    pub const Inst = instruction.Inst;

    pub const LoopInfo = block.LoopInfo;
    pub const BasicBlock = block.BasicBlock;

    pub const FuncParam = function.FuncParam;
    pub const CallingConvention = function.CallingConvention;
    pub const Function = function.Function;

    pub const MemRegion = module.MemRegion;
    pub const ResourceDecl = module.ResourceDecl;
    pub const Module = module.Module;
};

// ─── Flat re-exports (backward compat: bir.ValueId, bir.Module, etc.) ───
pub const ValueId = ir.ValueId;
pub const BlockId = ir.BlockId;
pub const FunctionId = ir.FunctionId;
pub const INVALID_ID = ir.INVALID_ID;
pub const NO_VALUE = ir.NO_VALUE;
pub const InstRef = ir.InstRef;
pub const ValueInfo = ir.ValueInfo;

pub const TypeId = ir.TypeId;
pub const INVALID_TYPE = ir.INVALID_TYPE;
pub const ScalarKind = ir.ScalarKind;
pub const AddressSpace = ir.AddressSpace;
pub const Type = ir.Type;
pub const TypeTable = ir.TypeTable;
pub const scalarBitSize = types.scalarBitSize;

pub const Op = ir.Op;
pub const ConstData = ir.ConstData;
pub const PhiIncoming = ir.PhiIncoming;
pub const MemoryOrder = ir.MemoryOrder;
pub const AtomicOp = ir.AtomicOp;
pub const CastKind = ir.CastKind;
pub const BarrierKind = ir.BarrierKind;
pub const SampleInfo = ir.SampleInfo;
pub const GepInfo = ir.GepInfo;
pub const CallInfo = ir.CallInfo;
pub const Inst = ir.Inst;
pub const collectDataRefs = instruction.collectDataRefs;

pub const LoopInfo = ir.LoopInfo;
pub const BasicBlock = ir.BasicBlock;

pub const FuncParam = ir.FuncParam;
pub const CallingConvention = ir.CallingConvention;
pub const Function = ir.Function;
pub const registerDataUses = function.registerDataUses;
pub const unregisterDataUses = function.unregisterDataUses;

pub const MemRegion = ir.MemRegion;
pub const ResourceDecl = ir.ResourceDecl;
pub const Module = ir.Module;

// ─── Analysis infrastructure ───
pub const AnalysisManager = @import("analysis/manager.zig").AnalysisManager;

// ─── Pass infrastructure ───
pub const AnalysisKind = @import("optimizer/pass_types.zig").AnalysisKind;
pub const PreservedAnalyses = @import("optimizer/pass_types.zig").PreservedAnalyses;
pub const ChangeSet = @import("optimizer/pass_types.zig").ChangeSet;
pub const PassContext = @import("optimizer/pass_manager.zig").PassContext;
pub const PassType = @import("optimizer/pass_manager.zig").PassType;
pub const Pass = @import("optimizer/pass_manager.zig").Pass;
pub const PassManager = @import("optimizer/pass_manager.zig").PassManager;
