const std = @import("std");

pub const Reg = enum(i16) {
    rax = 0, rcx = 1, rdx = 2, rbx = 3,
    rsp = 4, rbp = 5, rsi = 6, rdi = 7,
    r8 = 8, r9 = 9, r10 = 10, r11 = 11,
    r12 = 12, r13 = 13, r14 = 14, r15 = 15,
    xmm0 = 16, xmm1 = 17, xmm2 = 18, xmm3 = 19,
    xmm4 = 20, xmm5 = 21, xmm6 = 22, xmm7 = 23,
    xmm8 = 24, xmm9 = 25, xmm10 = 26, xmm11 = 27,
    xmm12 = 28, xmm13 = 29, xmm14 = 30, xmm15 = 31,
};

pub const MOperand = union(enum) {
    vreg: u32,
    phys: Reg,
    imm: i64,
    mem: MemOp,
};

pub const MemOp = struct {
    base: Reg,
    offset: i32,
    size: u8,
};

pub const CondCode = enum(u8) {
    eq = 4,
    ne = 5,
    lt = 0xC,
    le = 0xE,
    gt = 0xF,
    ge = 0xD,
};

pub const MovInst = struct { dst: MOperand, src: MOperand };
pub const AddInst = struct { dst: MOperand, src: MOperand };
pub const SubInst = struct { dst: MOperand, src: MOperand };
pub const IMulInst = struct { dst: MOperand, src: MOperand };
pub const IDivInst = struct { dst: MOperand, src: MOperand };
pub const CmpInst = struct { cc: CondCode, dst: MOperand, a: MOperand, b: MOperand };
pub const CmpFlagsInst = struct { a: MOperand, b: MOperand };
pub const JmpInst = struct { target: usize };
pub const JccInst = struct { cc: CondCode, target: usize };
pub const CallInst = struct { name: []const u8, args: [4]MOperand, arg_count: u32, dst: MOperand };
pub const AllocaInst = struct { size: u32, dst: MOperand };
pub const LoadInst = struct { dst: MOperand, ptr: MOperand };
pub const StoreInst = struct { ptr: MOperand, src: MOperand };
pub const RetInst = struct { val: MOperand, is_void: bool = false };

pub const PhiIncoming = struct {
    src: MOperand,
    pred_block: usize,
};

pub const PhiInst = struct {
    dst: MOperand,
    incoming: []const PhiIncoming,
};

pub const MInst = union(enum) {
    mov: MovInst,
    add: AddInst,
    sub: SubInst,
    imul: IMulInst,
    idiv: IDivInst,
    cmp: CmpInst,
    cmp_flags: CmpFlagsInst,
    jmp: JmpInst,
    jcc: JccInst,
    call: CallInst,
    alloca: AllocaInst,
    load: LoadInst,
    store: StoreInst,
    ret: RetInst,
    phi: PhiInst,
};

pub const MBlock = struct {
    label: []const u8,
    instrs: std.ArrayList(MInst),
};

pub const MFunction = struct {
    name: []const u8,
    params: []const MOperand,
    blocks: std.ArrayList(MBlock),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) MFunction {
        return .{
            .name = allocator.dupe(u8, name) catch "?",
            .params = &.{},
            .blocks = std.ArrayList(MBlock).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn setParams(self: *MFunction, params: []const MOperand) void {
        self.params = params;
    }

    pub fn deinit(self: *MFunction) void {
        self.allocator.free(self.name);
        self.allocator.free(self.params);
        for (self.blocks.items) |*b| {
            self.allocator.free(b.label);
            for (b.instrs.items) |*inst| {
                switch (inst.*) {
                    .call => self.allocator.free(inst.call.name),
                    .phi => |p| self.allocator.free(p.incoming),
                    else => {},
                }
            }
            b.instrs.deinit();
        }
        self.blocks.deinit();
    }
};
