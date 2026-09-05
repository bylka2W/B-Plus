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

    const semantic_mod = b.createModule(.{
        .root_source_file = b.path("tests/semantic/semantic_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    semantic_mod.addImport("frontend_test", b.createModule(.{
        .root_source_file = b.path("src/compiler/frontend/frontend_test.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const semtest_exe = b.addTest(.{
        .root_module = semantic_mod,
    });
    const semtest_run = b.addRunArtifact(semtest_exe);
    test_step.dependOn(&semtest_run.step);

    const test_exports_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/test_exports.zig"),
    });

    const test_cpu_exe = b.addExecutable(.{
        .name = "test_cpu",
        .root_source_file = b.path("tests/unit/test_cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_cpu_exe.root_module.addImport("test_exports", test_exports_mod);
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

    const test_fuzz_exe = b.addExecutable(.{
        .name = "test_fuzz",
        .root_source_file = b.path("tests/unit/test_mir_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_fuzz_exe.root_module.addImport("test_exports", test_exports_mod);
    const test_fuzz_run = b.addRunArtifact(test_fuzz_exe);
    const test_fuzz_step = b.step("test-fuzz", "Run MIR fuzzer tests");
    test_fuzz_step.dependOn(&test_fuzz_run.step);

}
