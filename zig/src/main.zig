const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const x64gen = @import("x64gen.zig");
const pe = @import("pe.zig");
const test_runner = @import("test_runner.zig");
const hlslgen = @import("hlslgen.zig");
const gpu_ast = @import("gpu_ast.zig");
const gpu_hlsl = @import("gpu_hlsl.zig");
const gpu_sema = @import("gpu_sema.zig");
const gpu_lower = @import("gpu_lower.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: bpc build <input.b+> [-o <output>] [-exports <name1,name2,...>]\n");
        try stderr.writeAll("       bpc dll  <input.b+> [-o <output.dll>] [-exports <name1,name2,...>]\n");
        try stderr.writeAll("       bpc run  <input.b+>\n");
        try stderr.writeAll("       bpc test <test.bpt>\n");
        try stderr.writeAll("       bpc hlsl <input.b+> [-o <output.hlsl>]\n");
        try stderr.writeAll("       bpc gpu  <input.b+> [-o <output.hlsl>]\n");
        std.process.exit(1);
    }

    const command = args[1];
    const input_path = args[2];

    var output_path: ?[]const u8 = null;
    var export_names: ?[]const u8 = null;
    {
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
                output_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "-exports") and i + 1 < args.len) {
                export_names = args[i + 1];
                i += 1;
            }
        }
    }

    var src = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(u32));
    defer allocator.free(src);

    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) {
        const stripped = try allocator.dupe(u8, src[3..]);
        allocator.free(src);
        src = stripped;
    }

    // Test command: parse .bpt, run tests, report
    if (std.mem.eql(u8, command, "test")) {
        const test_text = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(u32));
        defer allocator.free(test_text);

        const dir = if (std.mem.lastIndexOfScalar(u8, input_path, '\\')) |idx| input_path[0..idx] else if (std.mem.lastIndexOfScalar(u8, input_path, '/')) |idx| input_path[0..idx] else ".";
        const desc = try test_runner.parseTestDesc(allocator, test_text);
        // Resolve source path relative to .bpt directory
        const source_full = try std.fs.path.join(allocator, &.{ dir, desc.source });
        defer allocator.free(source_full);

        const stdout = std.io.getStdOut().writer();
        try stdout.print("TEST: {s}\n", .{desc.name});

        const result = try test_runner.runTest(allocator, source_full, desc, stdout);

        if (result.frames.len > 0) {
            var pass_count: usize = 0;
            var fail_count: usize = 0;
            for (result.frames) |fr| {
                for (fr.expects) |er| {
                    if (er.status == .pass) pass_count += 1 else fail_count += 1;
                }
            }
            try stdout.print("STATUS: {s} ({d} expect passed, {d} failed)\n", .{ @tagName(result.status), pass_count, fail_count });
        } else {
            try stdout.print("STATUS: {s}\n", .{@tagName(result.status)});
        }
        std.process.exit(if (result.status == .pass) 0 else 1);
    }

    // HLSL mode: generate HLSL shader text
    if (std.mem.eql(u8, command, "hlsl")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Auto-detect GPU kernel syntax
        const trimmed = std.mem.trim(u8, src, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "kernel ")) {
            try gpuCompileAndWrite(arena_alloc, src, input_path, output_path);
            return;
        }

        var p2 = parser.Parser.init(arena_alloc, src);
        const prog = try p2.parse();

        const output = try hlslgen.generate(arena_alloc, prog, src);
        const out_path = output_path orelse blk: {
            const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
            const base = input_path[0..ext_idx];
            break :blk try std.fmt.allocPrint(arena_alloc, "{s}.hlsl", .{base});
        };

        try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output.text });
        const stdout = std.io.getStdOut().writer();
        try stdout.print("HLSL written to {s}\n", .{out_path});
        return;
    }

    // GPU mode: parse GPU kernel and generate HLSL via parser.zig
    if (std.mem.eql(u8, command, "gpu")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        try gpuCompileAndWrite(arena_alloc, src, input_path, output_path);
        return;
    }

    var p = parser.Parser.init(allocator, src);
    var program = try p.parse();
    defer program.deinit();

    const is_dll = std.mem.eql(u8, command, "dll");

    // Mark entries as exports based on -exports flag
    if (is_dll) {
        if (export_names) |names| {
            var it = std.mem.splitScalar(u8, names, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " \t");
                for (program.entries.items) |*e| {
                    if (std.mem.eql(u8, e.name, trimmed)) {
                        e.is_export = true;
                    }
                }
            }
        }
    }

    var output = try if (is_dll) x64gen.generateEx(allocator, program, true, .off) else x64gen.generate(allocator, program);
    defer allocator.free(output.code);
    defer output.symbols.deinit();

    const out_path = output_path orelse blk: {
        const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
        const base = input_path[0..ext_idx];
        const ext = if (is_dll) ".dll" else ".exe";
        break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ext });
    };
    defer if (output_path == null) allocator.free(out_path);

    var pe_bytes: []u8 = undefined;
    if (is_dll) {
        var resolved = std.ArrayList(pe.ResolvedExport).init(allocator);
        defer resolved.deinit();
        for (output.symbols.symbols.items) |s| {
            if (s.kind == .exp) {
                try resolved.append(.{
                    .name = s.name,
                    .rva = if (s.forward_to == null) pe.section_rva + s.rva else 0,
                    .forward_to = s.forward_to,
                });
            }
        }
        pe_bytes = try pe.writeDll(allocator, output.code, output.import_dir_rva, output.idat_size, resolved.items);
    } else {
        pe_bytes = try pe.write(allocator, output.code, output.import_dir_rva, output.idat_size, output.entry_point_rva);
    }
    defer allocator.free(pe_bytes);

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = pe_bytes });

    if (std.mem.eql(u8, command, "run")) {
        var child = std.process.Child.init(&[_][]const u8{ out_path }, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        const term = try child.spawnAndWait();
        std.process.exit(switch (term) {
            .Exited => |code| code,
            else => 1,
        });
    }
}

fn gpuCompileAndWrite(arena_alloc: std.mem.Allocator, src: []const u8, input_path: []const u8, output_path_arg: ?[]const u8) !void {
    var p = parser.Parser.init(arena_alloc, src);
    const kernel = p.parseGpuKernelBlock() catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("GPU parse error: {}\n", .{err});
        std.process.exit(1);
    };

    var module = gpu_ast.GpuModule{
        .allocator = arena_alloc,
        .kernels = std.ArrayList(gpu_ast.GpuKernel).init(arena_alloc),
    };
    try module.kernels.append(kernel);

    var sema = gpu_sema.GpuSema.init(arena_alloc);
    sema.analyze(&module);
    if (sema.hasErrors()) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Semantic errors:\n");
        try sema.printDiagnostics(stderr);
        std.process.exit(1);
    }

    // Lower AST → IR, then generate HLSL from IR
    const ir = try gpu_lower.lowerModule(arena_alloc, &module);
    const hlsl = try gpu_hlsl.generateHlslFromIr(arena_alloc, &ir);
    const out_path = output_path_arg orelse blk: {
        const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
        const base = input_path[0..ext_idx];
        break :blk try std.fmt.allocPrint(arena_alloc, "{s}.hlsl", .{base});
    };
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = hlsl });
    const stdout = std.io.getStdOut().writer();
    try stdout.print("HLSL written to {s}\n", .{out_path});
}
