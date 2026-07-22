/// x64 instruction selection orchestration.
/// Routes MIR instructions to the appropriate sub-module for selection.
const std = @import("std");
const mir = @import("../../mir/mir.zig");
const regalloc = @import("../../regalloc/regalloc.zig");
const ctx_mod = @import("isel/context.zig");
const integer = @import("isel/integer.zig");
const float_sel = @import("isel/float.zig");
const memory = @import("isel/memory.zig");
const control = @import("isel/control.zig");
const conversions = @import("isel/conversions.zig");

pub const OffsetMap = ctx_mod.OffsetMap;
pub const BlockFixup = ctx_mod.BlockFixup;
pub const CallFixup = ctx_mod.CallFixup;
pub const SelectResult = ctx_mod.SelectResult;
pub const Ctx = ctx_mod.Ctx;

pub fn selectFunction(mfunc: *const mir.MFunction, ra: *const regalloc.RegAllocResult, alloca_offsets: OffsetMap) !SelectResult {
    const allocator = mfunc.allocator;
    var mf = ctx_mod.ir.MachineFunction.init(allocator, mfunc.name);
    errdefer mf.deinit();

    var block_fixups: std.ArrayListUnmanaged(BlockFixup) = .{};
    errdefer block_fixups.deinit(allocator);
    var call_fixups: std.ArrayListUnmanaged(CallFixup) = .{};
    errdefer call_fixups.deinit(allocator);

    var code_dummy = std.ArrayList(u8).init(allocator);
    defer code_dummy.deinit();

    const scratch: i16 = 11;

    for (mfunc.blocks.items) |*block| {
        const bi = try mf.appendBlock(block.label);
        var ctx = Ctx{
            .mf = &mf,
            .bi = bi,
            .ra = ra,
            .scratch = scratch,
            .mfunc = mfunc,
            .block_fixups = &block_fixups,
            .call_fixups = &call_fixups,
            .code_dummy = &code_dummy,
        };

        for (block.instrs.items) |inst| {
            switch (inst) {
                .mov => |m| try integer.selectMov(&ctx, m),
                .add => |a| try integer.selectAdd(&ctx, a),
                .sub => |s| try integer.selectSub(&ctx, s),
                .imul => |m| try integer.selectIMul(&ctx, m),
                .idiv => |m| try integer.selectIDiv(&ctx, m),
                .@"and" => |a| try integer.selectAnd(&ctx, a),
                .@"or" => |o| try integer.selectOr(&ctx, o),
                .xor => |x| try integer.selectXor(&ctx, x),
                .shl => |s| try integer.selectShift(&ctx, s, .SHIFT_LEFT_CL, .SHIFT_LEFT),
                .shr => |s| try integer.selectShift(&ctx, s, .SHR_R64_CL, .SHIFT_RIGHT),
                .sar => |s| try integer.selectShift(&ctx, s, .SAR_R64_CL, .SAR_R64_IMM32),
                .not_op => |n| try integer.selectNot(&ctx, n),
                .neg_op => |n| try integer.selectNeg(&ctx, n),
                .test_flags => |tf| try integer.selectTestFlags(&ctx, tf),
                .cmp => |c| try integer.selectCmp(&ctx, c),
                .cmp_flags => |cf| try integer.selectCmpFlags(&ctx, cf),
                .jmp => |j| try control.selectJmp(&ctx, j, allocator),
                .jcc => |j| try control.selectJcc(&ctx, j, allocator),
                .alloca => |a| try memory.selectAlloca(&ctx, a, alloca_offsets),
                .lea => |l| try memory.selectLea(&ctx, l),
                .load => |l| try memory.selectLoad(&ctx, l),
                .store => |s| try memory.selectStore(&ctx, s),
                .call => |c| try control.selectCall(&ctx, c),
                .ret => |r| try control.selectRet(&ctx, r),
                .phi => unreachable,
                .fadd => |f| try float_sel.selectFBinOp(&ctx, f, .SSE_ADDSS, .SSE_ADDSD),
                .fsub => |f| try float_sel.selectFBinOp(&ctx, f, .SSE_SUBSS, .SSE_SUBSD),
                .fmul => |f| try float_sel.selectFBinOp(&ctx, f, .SSE_MULSS, .SSE_MULSD),
                .fdiv => |f| try float_sel.selectFBinOp(&ctx, f, .SSE_DIVSS, .SSE_DIVSD),
                .fneg_op => |n| try float_sel.selectFNeg(&ctx, n),
                .fsqrt_op => |s| try float_sel.selectFSqrt(&ctx, s),
                .fcmp => |c| try float_sel.selectFCmp(&ctx, c),
                .sitofp => |c| try conversions.selectConv(&ctx, c, .SSE_CVTSI2SS, .SSE_CVTSI2SD, .SSE_CVTSI2SS_64, .SSE_CVTSI2SD_64),
                .fptosi => |c| try conversions.selectConv(&ctx, c, .SSE_CVTTSS2SI, .SSE_CVTTSD2SI, .SSE_CVTTSS2SI_64, .SSE_CVTTSD2SI_64),
                .fpext => |c| try conversions.selectConvSingle(&ctx, c, .SSE_CVTSS2SD),
                .fptrunc => |c| try conversions.selectConvSingle(&ctx, c, .SSE_CVTSD2SS),
                .sext_op => |c| try conversions.selectSext(&ctx, c),
                .zext_op => |c| try conversions.selectZext(&ctx, c),
                .trunc_op => |c| try conversions.selectTrunc(&ctx, c),
                .select => |s| try control.selectSelect(&ctx, s),
            }
        }
    }

    return SelectResult{
        .mf = mf,
        .block_fixups = block_fixups,
        .call_fixups = call_fixups,
    };
}

// Legacy re-exports for backward compatibility.
pub const resolveReg = ctx_mod.resolveReg;
