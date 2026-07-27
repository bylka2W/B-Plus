const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "bpc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run bpc");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/compiler/frontend/frontend_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run frontend + HIR lower tests");
    test_step.dependOn(&test_run.step);

    const test_hir_lower_exe = b.addTest(.{
        .root_source_file = b.path("src/compiler/hir_lower_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_hir_lower_run = b.addRunArtifact(test_hir_lower_exe);
    test_step.dependOn(&test_hir_lower_run.step);

    const test_cpu_exe = b.addExecutable(.{
        .name = "test_cpu",
        .root_source_file = b.path("tests/unit/test_cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_cpu_run = b.addRunArtifact(test_cpu_exe);
    const test_cpu_step = b.step("test-cpu", "Run CPU backend tests");
    test_cpu_step.dependOn(&test_cpu_run.step);

    const test_backend_analysis_exe = b.addExecutable(.{
        .name = "test_backend_analysis",
        .root_source_file = b.path("tests/unit/test_backend_analysis.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_backend_analysis_exe.root_module.addImport("bir_backend", b.createModule(.{
        .root_source_file = b.path("src/compiler/middle/bir/bir_backend.zig"),
    }));
    const test_backend_analysis_run = b.addRunArtifact(test_backend_analysis_exe);
    const test_backend_analysis_step = b.step("test-backend", "Run backend analysis tests (CFG, dominators, DF, mem2reg)");
    test_backend_analysis_step.dependOn(&test_backend_analysis_run.step);

    const test_bir_to_mir_exe = b.addExecutable(.{
        .name = "test_bir_to_mir_e2e",
        .root_source_file = b.path("test_bir_mir_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_bir_to_mir_run = b.addRunArtifact(test_bir_to_mir_exe);
    const test_bir_to_mir_step = b.step("test-bir-mir", "Run BIR→MIR end-to-end tests");
    test_bir_to_mir_step.dependOn(&test_bir_to_mir_run.step);

    const test_fuzz_exe = b.addExecutable(.{
        .name = "test_fuzz",
        .root_source_file = b.path("tests/unit/test_mir_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_fuzz_run = b.addRunArtifact(test_fuzz_exe);
    const test_fuzz_step = b.step("test-fuzz", "Run MIR fuzzer tests");
    test_fuzz_step.dependOn(&test_fuzz_run.step);

    const test_thir_exe = b.addTest(.{
        .root_source_file = b.path("src/thir_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_thir_run = b.addRunArtifact(test_thir_exe);
    const test_thir_step = b.step("test-thir", "Run THIR IR tests");
    test_thir_step.dependOn(&test_thir_run.step);

    const test_thir_to_bir_exe = b.addTest(.{
        .root_source_file = b.path("src/thir_to_bir_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_thir_to_bir_run = b.addRunArtifact(test_thir_to_bir_exe);
    const test_thir_to_bir_step = b.step("test-thir-to-bir", "Run THIR→BIR lowering tests");
    test_thir_to_bir_step.dependOn(&test_thir_to_bir_run.step);

    const test_mir_to_machine_exe = b.addExecutable(.{
        .name = "test_mir_to_machine",
        .root_source_file = b.path("test_mir_machine_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_mir_to_machine_run = b.addRunArtifact(test_mir_to_machine_exe);
    const test_mir_to_machine_step = b.step("test-mir-machine", "Run MIR→Machine IR lowering tests");
    test_mir_to_machine_step.dependOn(&test_mir_to_machine_run.step);

    const bplus_exe = b.addExecutable(.{
        .name = "bplus",
        .root_source_file = b.path("src/bplus.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(bplus_exe);
}
