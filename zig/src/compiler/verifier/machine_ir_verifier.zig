const std = @import("std");
const Allocator = std.mem.Allocator;
const machine = @import("../backend/machine/machine.zig");
const machine_verify = @import("../backend/machine/passes/verify.zig");
const VerifiedMachineIR = @import("verified_machine_ir.zig").VerifiedMachineIR;

pub const MachineIrVerifier = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) MachineIrVerifier {
        return .{ .allocator = allocator };
    }

    pub fn verify(self: *const MachineIrVerifier, module: *machine.MModule) !VerifiedMachineIR {
        try machine_verify.verifyModule(module);
        return VerifiedMachineIR{ .module = module, .allocator = self.allocator };
    }
};
