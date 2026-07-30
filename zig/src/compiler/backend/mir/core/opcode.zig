const operand = @import("operand.zig");
const MOperand = operand.MOperand;
const CondCode = operand.CondCode;

pub const MovInst = struct { dst: MOperand, src: MOperand };
pub const AddInst = struct { dst: MOperand, src: MOperand };
pub const SubInst = struct { dst: MOperand, src: MOperand };
pub const IMulInst = struct { dst: MOperand, src: MOperand };
pub const IDivInst = struct { dividend: MOperand, divisor: MOperand, quotient: MOperand, remainder: MOperand };
pub const AndInst = struct { dst: MOperand, src: MOperand };
pub const OrInst = struct { dst: MOperand, src: MOperand };
pub const XorInst = struct { dst: MOperand, src: MOperand };
pub const ShiftInst = struct { dst: MOperand, amount: MOperand, uses_cl: bool };
pub const UnaryInst = struct { dst: MOperand };
pub const FloatBinOp = struct { dst: MOperand, a: MOperand, b: MOperand };
pub const FCmpInst = struct { cc: CondCode, dst: MOperand, a: MOperand, b: MOperand };
pub const ConvInst = struct { dst: MOperand, src: MOperand };
pub const SelectInst = struct { dst: MOperand, src: MOperand, cc: CondCode };
pub const TestFlagsInst = struct { a: MOperand, b: MOperand };
pub const SetCCInst = struct { dst: MOperand, cc: CondCode };
pub const CmpInst = struct { cc: CondCode, a: MOperand, b: MOperand };
pub const CmpFlagsInst = struct { a: MOperand, b: MOperand };
pub const JmpInst = struct { target: u32 };
pub const JccInst = struct { cc: CondCode, target: u32 };
pub const CallInst = struct {
    name: []const u8,
    args: [14]MOperand,
    arg_count: u32,
    dst: MOperand,
    is_void: bool = false,
};
pub const AllocaInst = struct { size: u32, dst: MOperand };
pub const MemSize = enum { u8, u16, u32, u64, f32, f64, xmm128 };

pub const LoadInst = struct { dst: MOperand, ptr: MOperand, size: MemSize };
pub const StoreInst = struct { ptr: MOperand, src: MOperand, size: MemSize };
pub const LeaInst = struct {
    dst: MOperand,
    base: MOperand,
    index: MOperand = .{ .imm = 0 },
    scale: u8 = 1,
    disp: i32 = 0,
};
pub const RetInst = union(enum) {
    void_ret,
    value: MOperand,
};

pub const StateInitInst = struct { initial_state: MOperand };
pub const StateEnterInst = struct { state_id: MOperand };
pub const StateExitInst = struct { state_id: MOperand };
pub const EventDispatchInst = struct { dst: MOperand, buf: MOperand, size: MOperand };
pub const TransitionCheckInst = struct { result: MOperand, event: MOperand, event_id: u32 };
pub const GuardEvalInst = struct { result: MOperand, lhs: MOperand, rhs: MOperand, cc: CondCode };

pub const StringConstInst = struct {
    dst: MOperand,
    data: []const u8,
};

pub const PhiIncoming = struct {
    src: MOperand,
    pred_block: u32,
};

pub const PhiInst = struct {
    dst: MOperand,
    incoming: []const PhiIncoming,
};

pub const MInst = union(enum) {
    mov: MovInst,
    add: AddInst,
    sub: SubInst,
    string_const: StringConstInst,
    imul: IMulInst,
    idiv: IDivInst,
    @"and": AndInst,
    @"or": OrInst,
    xor: XorInst,
    shl: ShiftInst,
    shr: ShiftInst,
    sar: ShiftInst,
    not_op: UnaryInst,
    neg_op: UnaryInst,
    test_flags: TestFlagsInst,
    setcc: SetCCInst,
    cmp: CmpInst,
    cmp_flags: CmpFlagsInst,
    jmp: JmpInst,
    jcc: JccInst,
    call: CallInst,
    alloca: AllocaInst,
    load: LoadInst,
    store: StoreInst,
    lea: LeaInst,
    ret: RetInst,
    phi: PhiInst,
    fadd: FloatBinOp,
    fsub: FloatBinOp,
    fmul: FloatBinOp,
    fdiv: FloatBinOp,
    fneg_op: UnaryInst,
    fsqrt_op: UnaryInst,
    fcmp: FCmpInst,
    sitofp: ConvInst,
    fptosi: ConvInst,
    fpext: ConvInst,
    fptrunc: ConvInst,
    sext_op: ConvInst,
    zext_op: ConvInst,
    trunc_op: ConvInst,
    select: SelectInst,
    state_init: StateInitInst,
    state_enter: StateEnterInst,
    state_exit: StateExitInst,
    event_dispatch: EventDispatchInst,
    transition_check: TransitionCheckInst,
    guard_eval: GuardEvalInst,
};

pub const MInstUtils = struct {
    pub fn hasDst(inst: MInst) bool {
        return switch (inst) {
            .mov, .add, .sub, .imul,
            .@"and", .@"or", .xor,
            .shl, .shr, .sar,
            .not_op, .neg_op,
            .alloca, .load, .lea, .phi,
            .fadd, .fsub, .fmul, .fdiv,
            .fneg_op, .fsqrt_op,
            .fcmp,
            .sitofp, .fptosi, .fpext, .fptrunc,
            .sext_op, .zext_op, .trunc_op,
            .select,
            .setcc,
            .event_dispatch,
            .transition_check,
            .guard_eval,
            => true,
            .string_const => true,
            .idiv => true,
            .call => |c| !c.is_void,
            else => false,
        };
    }

    pub fn dstVReg(inst: MInst) ?u32 {
        return switch (inst) {
            .mov => |m| vregOf(m.dst),
            .add => |m| vregOf(m.dst),
            .sub => |m| vregOf(m.dst),
            .imul => |m| vregOf(m.dst),
            .idiv => |m| vregOf(m.quotient),
            .@"and" => |m| vregOf(m.dst),
            .@"or" => |m| vregOf(m.dst),
            .xor => |m| vregOf(m.dst),
            .shl, .shr, .sar => |m| vregOf(m.dst),
            .not_op, .neg_op => |m| vregOf(m.dst),
            .alloca => |m| vregOf(m.dst),
            .load => |m| vregOf(m.dst),
            .lea => |m| vregOf(m.dst),
            .call => |c| if (c.is_void) null else vregOf(c.dst),
            .phi => |p| vregOf(p.dst),
            .fadd, .fsub, .fmul, .fdiv => |m| vregOf(m.dst),
            .fneg_op, .fsqrt_op => |m| vregOf(m.dst),
            .fcmp => |c| vregOf(c.dst),
            .sitofp, .fptosi, .fpext, .fptrunc => |c| vregOf(c.dst),
            .sext_op, .zext_op, .trunc_op => |c| vregOf(c.dst),
            .select => |s| vregOf(s.dst),
            .setcc => |s| vregOf(s.dst),
            .string_const => |s| vregOf(s.dst),
            .event_dispatch => |m| vregOf(m.dst),
            .transition_check => |m| vregOf(m.result),
            .guard_eval => |m| vregOf(m.result),
            else => null,
        };
    }

    pub fn readsFlags(inst: MInst) bool {
        return switch (inst) {
            .jcc, .select => true,
            else => false,
        };
    }

    pub fn writesFlags(inst: MInst) bool {
        return switch (inst) {
            .add, .sub, .imul, .idiv,
            .@"and", .@"or", .xor,
            .shl, .shr, .sar,
            .not_op, .neg_op,
            .cmp, .cmp_flags, .test_flags,
            => true,
            else => false,
        };
    }

    pub fn isIntegerOp(inst: MInst) bool {
        return switch (inst) {
            .add, .sub, .imul, .idiv,
            .@"and", .@"or", .xor,
            .shl, .shr, .sar,
            .not_op, .neg_op,
            => true,
            else => false,
        };
    }

    fn vregOf(op: MOperand) ?u32 {
        return switch (op) {
            .vreg => |v| v,
            else => null,
        };
    }
};
