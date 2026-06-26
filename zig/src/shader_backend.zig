const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ir = @import("gpu_ir.zig");
const IrModule = gpu_ir.IrModule;
const CompileOptions = gpu_ir.CompileOptions;
const CompileResult = gpu_ir.CompileResult;
const BackendType = gpu_ir.BackendType;
const dxil = @import("dxil_backend.zig");

/// Registry of available shader backends.
/// Each backend compiles GPU IR (SSA) to target-specific bytecode.
pub const backends = struct {
    pub fn get(target: BackendType) ?gpu_ir.BackendApi {
        return switch (target) {
            .dxil => dxil.backend,
            .spirv => null,
            .msl => null,
        };
    }

    pub fn getFirst() ?gpu_ir.BackendApi {
        return dxil.backend;
    }

    pub fn count() usize {
        return 1;
    }
};
