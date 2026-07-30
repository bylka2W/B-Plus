const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../middle/bir/bir.zig");
const bir_verify = @import("../middle/bir/verify/verifier.zig");
const VerifiedBIR = @import("verified_bir.zig").VerifiedBIR;

pub const BirVerifier = struct {
    allocator: Allocator,
    options: bir_verify.VerifyOptions,

    pub fn init(allocator: Allocator) BirVerifier {
        return .{
            .allocator = allocator,
            .options = .{},
        };
    }

    pub fn verify(self: *const BirVerifier, module: *bir.Module) !VerifiedBIR {
        var result = bir_verify.verify(module, self.options);
        defer result.deinit();
        if (!result.isValid()) {
            const stderr = std.io.getStdErr().writer();
            try result.printErrors(stderr, module);
        }
        try result.expectValid();
        return VerifiedBIR{ .module = module, .allocator = self.allocator };
    }
};
