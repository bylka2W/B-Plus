const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const gpu_ir = @import("gpu_ir.zig");
const gpu_hlsl = @import("gpu_hlsl.zig");
const IrModule = gpu_ir.IrModule;
const CompileOptions = gpu_ir.CompileOptions;
const CompileResult = gpu_ir.CompileResult;
const BackendType = gpu_ir.BackendType;

pub const backend = gpu_ir.BackendApi{
    .name = "DXIL (DXC)",
    .target = .dxil,
    .compile = &compile,
};

const dxc_paths = [_][]const u8{
    "C:\\tools\\DXC\\build\\native\\bin\\x64\\dxc.exe",
    "C:\\Program Files (x86)\\Windows Kits\\10\\bin\\10.0.26100.0\\x64\\dxc.exe",
    "dxc.exe",
};

fn findDxc(_: Allocator) ![]const u8 {
    for (dxc_paths) |path| {
        fs.accessAbsolute(path, .{}) catch continue;
        return path;
    }
    return error.DxcNotFound;
}

fn compile(allocator: Allocator, ir: *const IrModule, options: CompileOptions) !CompileResult {
    _ = options;
    const dxc_path = try findDxc(allocator);
    const hlsl = try gpu_hlsl.generateHlslFromIr(allocator, ir);
    defer allocator.free(hlsl);
    return compileHlslWithPath(allocator, dxc_path, hlsl);
}

/// Direct HLSL → DXIL compilation (for transition period)
pub fn compileHlsl(allocator: Allocator, hlsl: []const u8) !CompileResult {
    const dxc_path = try findDxc(allocator);
    return compileHlslWithPath(allocator, dxc_path, hlsl);
}

fn compileHlslWithPath(allocator: Allocator, dxc_path: []const u8, hlsl: []const u8) !CompileResult {
    const tmp_dir = "C:\\Windows\\Temp";
    const suffix = std.time.microTimestamp();
    const in_path = try std.fmt.allocPrint(allocator, "{s}\\bplus_dxil_{d}.hlsl", .{ tmp_dir, suffix });
    defer allocator.free(in_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}\\bplus_dxil_{d}.cso", .{ tmp_dir, suffix });
    defer allocator.free(out_path);

    {
        const f = try fs.createFileAbsolute(in_path, .{});
        defer f.close();
        try f.writeAll(hlsl);
    }
    defer fs.deleteFileAbsolute(in_path) catch {};
    defer fs.deleteFileAbsolute(out_path) catch {};

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.append(dxc_path);
    try args.append("-T");
    try args.append("cs_6_6");
    try args.append("-E");
    try args.append("main");
    try args.append("-Fo");
    try args.append(out_path);
    try args.append(in_path);

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    const err_msg = if (child.stderr) |stderr_pipe|
        stderr_pipe.readToEndAlloc(allocator, 4096) catch &.{}
    else
        &.{};
    defer if (err_msg.len > 0) allocator.free(err_msg);

    const out_msg = if (child.stdout) |stdout_pipe|
        stdout_pipe.readToEndAlloc(allocator, 4096) catch &.{}
    else
        &.{};
    defer if (out_msg.len > 0) allocator.free(out_msg);

    if (term != .Exited or term.Exited != 0) {
        std.debug.print("DXC failed (exit={})\nerr:{s}\nout:{s}\n", .{ if (term == .Exited) term.Exited else 0, err_msg, out_msg });
        return error.DxcCompileFailed;
    }

    const file = try fs.openFileAbsolute(out_path, .{});
    defer file.close();
    const stat = try file.stat();
    const bytecode = try file.readToEndAlloc(allocator, @as(usize, @intCast(stat.size)));

    std.debug.print("DXIL compiled: {} bytes\n", .{bytecode.len});
    return CompileResult{ .bytecode = bytecode, .allocator = allocator };
}
