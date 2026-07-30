const std = @import("std");
const Allocator = std.mem.Allocator;
const mir = @import("../backend/mir/mir.zig");
const VerifiedMIR = @import("verified_mir.zig").VerifiedMIR;

pub const MirVerifier = struct {
    allocator: Allocator,
    errors: std.ArrayList(MirVerifyError),

    pub const MirVerifyError = union(enum) {
        empty_function: []const u8,
        undefined_vreg: struct { func: []const u8, vreg: u32 },
        duplicate_vreg_def: struct { func: []const u8, vreg: u32 },
        invalid_block_target: struct { func: []const u8, block: u32 },
        missing_entry_block: []const u8,
    };

    pub fn init(allocator: Allocator) MirVerifier {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(MirVerifyError).init(allocator),
        };
    }

    pub fn deinit(self: *MirVerifier) void {
        self.errors.deinit();
    }

    pub fn verify(self: *MirVerifier, module: *mir.MModule) !VerifiedMIR {
        for (module.functions.items) |*func| {
            try self.verifyFunction(func);
        }

        if (self.errors.items.len > 0) {
            return error.VerificationFailed;
        }

        return VerifiedMIR{ .module = module, .allocator = self.allocator };
    }

    fn verifyFunction(self: *MirVerifier, func: *const mir.MFunction) !void {
        if (func.blocks.items.len == 0) {
            try self.errors.append(.{ .empty_function = func.name });
            return;
        }

        for (func.blocks.items, 0..) |*blk, bi| {
            for (blk.instrs.items) |inst| {
                try self.checkVRegDef(func, inst);
                try self.checkVRegUse(func, inst, bi);
            }
        }
    }

    fn checkVRegDef(_: *MirVerifier, _: *const mir.MFunction, inst: mir.MInst) !void {
        _ = inst;
    }

    fn checkVRegUse(_: *MirVerifier, func: *const mir.MFunction, inst: mir.MInst, _: usize) !void {
        _ = func;
        _ = inst;
    }

    fn dstVReg(inst: mir.MInst) ?u32 {
        return switch (inst) {
            .mov => |i| vregOp(i.dst),
            .add => |i| vregOp(i.dst),
            .sub => |i| vregOp(i.dst),
            .@"and" => |i| vregOp(i.dst),
            .@"or" => |i| vregOp(i.dst),
            .xor => |i| vregOp(i.dst),
            .imul => |i| vregOp(i.dst),
            .load => |i| vregOp(i.dst),
            .lea => |i| vregOp(i.dst),
            .alloca => |i| vregOp(i.dst),
            .call => |i| if (i.is_void) null else vregOp(i.dst),
            .phi => |i| vregOp(i.dst),
            else => null,
        };
    }

    fn vregOp(op: mir.MOperand) ?u32 {
        return switch (op) {
            .vreg => |v| v,
            else => null,
        };
    }
};
