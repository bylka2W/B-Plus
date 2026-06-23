const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const x64gen = @import("x64gen.zig");
const pe = @import("pe.zig");
const test_runner = @import("test_runner.zig");
const hlslgen = @import("hlslgen.zig");

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

    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) {
        const stripped = try allocator.dupe(u8, src[3..]);
        allocator.free(src);
        src = stripped;
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
                    .rva = pe.section_rva + s.rva,
                });
            }
        }
        pe_bytes = try pe.writeDll(allocator, output.code, output.import_dir_rva, output.idat_size, resolved.items);
    } else {
        pe_bytes = try pe.write(allocator, output.code, output.import_dir_rva, output.idat_size);
    }
    defer allocator.free(pe_bytes);

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = pe_bytes });

    if (std.mem.eql(u8, command, "run")) {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ out_path },
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(result.stdout);
        const stderr = std.io.getStdErr().writer();
        if (result.stderr.len > 0) try stderr.writeAll(result.stderr);
        std.process.exit(result.term.Exited);
    }
}
