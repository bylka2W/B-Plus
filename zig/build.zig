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

    const test_exe = b.addExecutable(.{
        .name = "test_bir_frontend",
        .root_source_file = b.path("src/test_bir_frontend.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);

    const test_cpu_exe = b.addExecutable(.{
        .name = "test_cpu",
        .root_source_file = b.path("src/test_cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_cpu_run = b.addRunArtifact(test_cpu_exe);
    const test_cpu_step = b.step("test-cpu", "Run CPU backend tests");
    test_cpu_step.dependOn(&test_cpu_run.step);

    const test_fuzz_exe = b.addExecutable(.{
        .name = "test_fuzz",
        .root_source_file = b.path("src/test_mir_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_fuzz_run = b.addRunArtifact(test_fuzz_exe);
    const test_fuzz_step = b.step("test-fuzz", "Run MIR fuzzer tests");
    test_fuzz_step.dependOn(&test_fuzz_run.step);

    const bplus_exe = b.addExecutable(.{
        .name = "bplus",
        .root_source_file = b.path("src/bplus.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(bplus_exe);
}
