///проверяет x64 IR
const std = @import("std");
const ir = @import("../ir/inst.zig");
const OpCode = ir.OpCode;
const Operand = ir.Operand;

pub const VerifyError = error{
    InvalidRegister,
    MissingOperands,
    ExtraOperands,
    ImmForbidden,
    RegForbidden,
    MemForbidden,
    InvalidMemoryOperand,
};

pub const VerifiedX64Function = struct {
    mf: *const ir.MachineFunction,
};

fn isReg(operand: Operand) bool {
    return operand.reg >= 0 and (operand.reg <= 15 or operand.is_xmm);
}

fn isMem(operand: Operand) bool {
    return operand.base_reg >= 0 or operand.base_reg == 255;
}

fn isImm(operand: Operand) bool {
    return operand.reg < 0 and operand.base_reg < 0 and operand.index_reg < 0;
}

fn checkRegs(inst: ir.Instruction, comptime indices: []const usize) !void {
    for (indices) |i| {
        if (i >= inst.olen) return error.MissingOperands;
        if (!isReg(inst.operands[i])) return error.InvalidRegister;
    }
}

fn checkImm(inst: ir.Instruction, i: usize) !void {
    if (i >= inst.olen) return error.MissingOperands;
    if (!isImm(inst.operands[i])) return error.InvalidRegister;
}

fn checkMem(inst: ir.Instruction, i: usize) !void {
    if (i >= inst.olen) return error.MissingOperands;
    if (!isMem(inst.operands[i])) return error.InvalidMemoryOperand;
}

fn checkOlen(inst: ir.Instruction, expected: usize) !void {
    if (inst.olen != expected) {
        if (inst.olen < expected) return error.MissingOperands;
        return error.ExtraOperands;
    }
}

fn verifyRR(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{ 0, 1 });
}

fn verifyRI(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{0});
    try checkImm(inst, 1);
}

fn verifyRM(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{0});
    try checkMem(inst, 1);
}

fn verifyMR(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkMem(inst, 0);
    try checkRegs(inst, &.{1});
}

fn verifyR(inst: ir.Instruction) !void {
    try checkOlen(inst, 1);
    try checkRegs(inst, &.{0});
}

fn verifyNone(inst: ir.Instruction) !void {
    try checkOlen(inst, 0);
}

fn verifyBranch(inst: ir.Instruction) !void {
    try checkOlen(inst, 1);
    try checkImm(inst, 0);
}

fn verifySetcc(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{0});
    try checkImm(inst, 1);
}

fn verifyCmovRR(inst: ir.Instruction) !void {
    try checkOlen(inst, 3);
    try checkRegs(inst, &.{ 0, 1 });
    try checkImm(inst, 2);
}

fn verifyCmovRM(inst: ir.Instruction) !void {
    try checkOlen(inst, 3);
    try checkRegs(inst, &.{0});
    try checkMem(inst, 1);
    try checkImm(inst, 2);
}

fn verifySSE2(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{0});
    if (!isReg(inst.operands[1]) and !isMem(inst.operands[1])) {
        return error.InvalidRegister;
    }
}

fn verifySSE3(inst: ir.Instruction) !void {
    try checkOlen(inst, 3);
    try checkRegs(inst, &.{0});
    if (!isReg(inst.operands[1]) and !isMem(inst.operands[1])) {
        return error.InvalidRegister;
    }
    try checkImm(inst, 2);
}

fn verifyCallRipdisp(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{0});
    try checkMem(inst, 1);
}

fn verifyMov64MemRip(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{0});
    try checkMem(inst, 1);
}

fn verifyPrefetch(inst: ir.Instruction) !void {
    try checkOlen(inst, 0);
}

fn verifyMov64Imm(inst: ir.Instruction) !void {
    try checkOlen(inst, 2);
    try checkRegs(inst, &.{0});
}

pub fn verifyInst(inst: ir.Instruction) !void {
    switch (inst.op) {
        .MOV_R64_R64, .MOV_R32_R32, .ADD_R64_R64, .ADD_R32_R32,
        .SUB_R64_R64, .SUB_R32_R32, .CMP_R64_R64, .CMP_R32_R32,
        .TEST_R64_R64, .TEST_R32_R32, .XOR_R64_R64, .XOR_R32_R32,
        .IMUL_R64_R64, .IMUL_R32_R32, .AND_R64_R64, .AND_R32_R32,
        .OR_R64_R64, .OR_R32_R32, .MOVSX_R64_R32,
        .IMUL_R64_IMM32,
        => try verifyRR(inst),

        .MOV_R64_IMM64, .ADD_R64_IMM32, .ADD_R32_IMM32,
        .SUB_R64_IMM32, .SUB_R32_IMM32,
        .CMP_R64_IMM32, .CMP_R32_IMM32,
        .AND_R64_IMM32, .OR_R64_IMM32, .XOR_R64_IMM32,
        .TEST_R64_IMM32,
        .SAR_R64_IMM32, .SAR_R32_IMM32,
        .SHIFT_LEFT, .SHIFT_LEFT_32, .SHIFT_RIGHT, .SHIFT_RIGHT_32,
        => try verifyRI(inst),

        .MOV_R64_MEM, .MOV_R32_MEM, .ADD_R64_MEM, .SUB_R64_MEM,
        .CMP_R64_MEM, .LEA_R64_MEM,
        .MOVZX_R64_MEM8, .MOVZX_R64_MEM16,
        .MOVSX_R64_MEM8, .MOVSX_R64_MEM16,
        .MOVZX_R64_R32,
        => try verifyRM(inst),

        .MOV_MEM_R64, .MOV_MEM_R32, .MOV_MEM_R16, .MOV_MEM_R8,
        => try verifyMR(inst),

        .NOT_R64, .NEG_R64, .NOT_R32, .NEG_R32,
        .IDIV_R64, .PUSH_R64, .POP_R64, .CALL_R64,
        .SHIFT_LEFT_CL, .SHIFT_RIGHT_CL, .SAR_R64_CL,
        .SHR_R64_CL, .SHR_R32_CL,
        => try verifyR(inst),

        .CQO,
        => try verifyNone(inst),

        .RET, .NOP, .INT3, .UD2, .PUSHFQ, .POPFQ,
        => try verifyNone(inst),

        .JMP_REL32, .CALL_REL32,
        .JE_REL32, .JNE_REL32, .JG_REL32, .JGE_REL32,
        .JL_REL32, .JLE_REL32, .JA_REL32, .JB_REL32, .JBE_REL32, .JAE_REL32,
        => try verifyBranch(inst),

        .SETCC_R8 => try verifySetcc(inst),
        .CMOV_R64_R64 => try verifyCmovRR(inst),
        .CMOV_R64_MEM => try verifyCmovRM(inst),

        .SSE_MOVUPS_LD, .SSE_MOVUPS_ST, .SSE_MOVAPS_LD, .SSE_MOVAPS_ST,
        .SSE_ADDPS, .SSE_SUBPS, .SSE_MULPS, .SSE_DIVPS,
        .SSE_MINPS, .SSE_MAXPS, .SSE_SQRTPS, .SSE_MOVLHPS,
        .SSE_MOVSS_LD, .SSE_MOVSS_ST,
        .SSE_ADDSS, .SSE_SUBSS, .SSE_MULSS, .SSE_DIVSS,
        .SSE_MINSS, .SSE_MAXSS,
        .SSE_CVTSI2SS, .SSE_CVTTSS2SI, .SSE_UCOMISS,
        .SSE_SQRTSS, .SSE_RSQRTSS,
        .SSE_MOVD_LD, .SSE_MOVD_ST,
        .SSE_MOVQ_LD, .SSE_MOVQ_ST,
        .SSE_MOVSD_LD, .SSE_MOVSD_ST,
        .SSE_XORPS,
        .SSE_ADDSD, .SSE_SUBSD, .SSE_MULSD, .SSE_DIVSD,
        .SSE_MINSD, .SSE_MAXSD,
        .SSE_CVTSI2SD, .SSE_CVTTSD2SI,
        .SSE_CVTSS2SD, .SSE_CVTSD2SS,
        .SSE_UCOMISD, .SSE_SQRTSD,
        .SSE_HADDPS,
        .SSE_CVTSI2SS_64, .SSE_CVTSI2SD_64,
        .SSE_CVTTSS2SI_64, .SSE_CVTTSD2SI_64,
        => try verifySSE2(inst),

        .SSE_SHUFPS, .SSE_DPPS, .SSE_ROUNDSS,
        => try verifySSE3(inst),

        .CALL_RIPDISP => try verifyCallRipdisp(inst),
        .MOV_R64_MEM_RIP => try verifyMov64MemRip(inst),

        .PREFETCHT0_RIPREL, .PREFETCHT1_RIPREL, .PREFETCHT2_RIPREL,
        => try verifyPrefetch(inst),
    }
}

pub fn verifyFunction(mf: *const ir.MachineFunction) !VerifiedX64Function {
    for (mf.blocks.items, 0..) |*block, bi| {
        for (block.instrs.items, 0..) |inst, ii| {
            verifyInst(inst) catch |err| {
                std.debug.print(
                    "x64 IR verify error in {s} block {s}[{}] instr[{}]: {}\n",
                    .{ mf.name, block.label, bi, ii, err },
                );
                std.debug.print("  op={s} olen={}\n", .{ @tagName(inst.op), inst.olen });
                for (inst.operands[0..inst.olen]) |op| {
                    std.debug.print("    reg={d} base={d} idx={d} disp={d} imm64={x} is_xmm={}\n", .{ op.reg, op.base_reg, op.index_reg, op.disp, op.imm64, op.is_xmm });
                }
                return err;
            };
        }
    }
    return .{ .mf = mf };
}

const regNames = [_][:0]const u8{
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
};

fn operandFmt(operand: Operand, writer: anytype) !void {
    if (operand.reg >= 0) {
        if (operand.is_xmm) {
            try writer.print("xmm{d}", .{operand.reg});
        } else {
            try writer.print("{s}", .{regNames[@as(usize, @intCast(operand.reg & 15))]});
        }
    } else if (operand.base_reg == 255) {
        try writer.print("[rip+{d}]", .{operand.disp});
    } else if (operand.base_reg >= 0) {
        if (operand.index_reg >= 0) {
            try writer.print("[{s}+{s}*{}+{}]", .{
                regNames[@as(usize, @intCast(operand.base_reg & 15))],
                regNames[@as(usize, @intCast(operand.index_reg & 15))],
                operand.scale,
                operand.disp,
            });
        } else {
            try writer.print("[{s}+{d}]", .{
                regNames[@as(usize, @intCast(operand.base_reg & 15))],
                operand.disp,
            });
        }
    } else {
        try writer.print("#{x}", .{operand.imm64});
    }
}

pub fn dumpFunction(vf: VerifiedX64Function) void {
    const mf = vf.mf;
    const stderr = std.io.getStdErr().writer();
    stderr.print("[DUMP] x64 IR verified function {s}\n\n", .{mf.name}) catch return;
    for (mf.blocks.items) |*block| {
        stderr.print("  {s}:\n", .{block.label}) catch return;
        for (block.instrs.items, 0..) |inst, ii| {
            stderr.print("    {:4}: {s}", .{ ii, @tagName(inst.op) }) catch return;
            if (inst.olen > 0) {
                stderr.print(" ", .{}) catch return;
                operandFmt(inst.operands[0], stderr) catch return;
                for (1..inst.olen) |j| {
                    stderr.print(", ", .{}) catch return;
                    operandFmt(inst.operands[j], stderr) catch return;
                }
            }
            stderr.print("\n", .{}) catch return;
        }
        stderr.print("\n", .{}) catch return;
    }
}

test "verified type barrier" {
    const testing = std.testing;
    var mf = ir.MachineFunction.init(testing.allocator, "test");
    defer mf.deinit();
    _ = try mf.appendBlock("entry");
    try mf.appendInstr1(0, .RET, .{});
    _ = try verifyFunction(&mf);
}

test "catches extra operands" {
    const testing = std.testing;
    var mf = ir.MachineFunction.init(testing.allocator, "test");
    defer mf.deinit();
    _ = try mf.appendBlock("entry");
    try mf.appendInstr(0, .CALL_REL32, &.{ .{ .imm64 = 0 }, .{ .reg = 0 } });
    try testing.expectError(error.ExtraOperands, verifyFunction(&mf));
}

test "catches missing operands" {
    const testing = std.testing;
    var mf = ir.MachineFunction.init(testing.allocator, "test");
    defer mf.deinit();
    _ = try mf.appendBlock("entry");
    try mf.appendInstr1(0, .MOV_R64_R64, .{ .reg = 0 });
    try testing.expectError(error.MissingOperands, verifyFunction(&mf));
}

test "catches immediate in register slot" {
    const testing = std.testing;
    var mf = ir.MachineFunction.init(testing.allocator, "test");
    defer mf.deinit();
    _ = try mf.appendBlock("entry");
    try mf.appendInstr(0, .MOV_R64_R64, &.{ .{ .reg = 0 }, Operand.imm(42) });
    try testing.expectError(error.InvalidRegister, verifyFunction(&mf));
}

test "catches invalid register number" {
    const testing = std.testing;
    var mf = ir.MachineFunction.init(testing.allocator, "test");
    defer mf.deinit();
    _ = try mf.appendBlock("entry");
    try mf.appendInstr1(0, .RET, .{ .reg = 99 });
    try testing.expectError(error.ExtraOperands, verifyFunction(&mf));
}

test "verifies valid function" {
    const testing = std.testing;
    var mf = ir.MachineFunction.init(testing.allocator, "test");
    defer mf.deinit();
    _ = try mf.appendBlock("entry");
    try mf.appendInstr2(0, .MOV_R64_R64, .{ .reg = 0 }, .{ .reg = 1 });
    try mf.appendInstr1(0, .RET, .{});
    _ = try verifyFunction(&mf);
}
