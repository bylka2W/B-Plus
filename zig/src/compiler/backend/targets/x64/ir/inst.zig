const std = @import("std");
const x64enc = @import("../encoder/x64enc.zig");

pub const OpCode = x64enc.OpCode;

pub const Operand = x64enc.Operand;

pub const Instruction = struct {
    op: OpCode,
    operands: [3]Operand,
    olen: u2,
};

pub const MachineBlock = struct {
    label: []const u8,
    instrs: std.ArrayListUnmanaged(Instruction),
};

pub const MachineFunction = struct {
    name: []const u8,
    blocks: std.ArrayListUnmanaged(MachineBlock),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) MachineFunction {
        return .{
            .name = name,
            .blocks = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MachineFunction) void {
        for (self.blocks.items) |*b| {
            b.instrs.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
    }

    pub fn appendBlock(self: *MachineFunction, label: []const u8) !usize {
        const idx = self.blocks.items.len;
        try self.blocks.append(self.allocator, .{
            .label = label,
            .instrs = .{},
        });
        return idx;
    }

    pub fn appendInstr(self: *MachineFunction, block_idx: usize, op: OpCode, operands: []const Operand) !void {
        const block = &self.blocks.items[block_idx];
        var instr = Instruction{
            .op = op,
            .operands = .{ .{}, .{}, .{} },
            .olen = @intCast(operands.len),
        };
        for (operands, 0..) |o, i| {
            instr.operands[i] = o;
        }
        try block.instrs.append(self.allocator, instr);
    }

    pub fn appendInstr2(self: *MachineFunction, block_idx: usize, op: OpCode, o1: Operand, o2: Operand) !void {
        try self.appendInstr(block_idx, op, &.{ o1, o2 });
    }

    pub fn appendInstr1(self: *MachineFunction, block_idx: usize, op: OpCode, o1: Operand) !void {
        try self.appendInstr(block_idx, op, &.{o1});
    }
};
