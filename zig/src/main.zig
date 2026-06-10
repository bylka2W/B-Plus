const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const x64gen = @import("x64gen.zig");
const pe = @import("pe.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: bpc build <input.b+> [-o <output.exe>]\n");
        try stderr.writeAll("       bpc run  <input.b+>\n");
        std.process.exit(1);
    }

    const command = args[1];
    const input_path = args[2];

    // Find output path
    var output_path: ?[]const u8 = null;
    {
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
                output_path = args[i + 1];
                break;
            }
        }
    }

    // Read input file
    var src = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(u32));
    defer allocator.free(src);

    // Strip UTF-8 BOM if present
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) {
        const stripped = try allocator.dupe(u8, src[3..]);
        allocator.free(src);
        src = stripped;
    }

    // Parse
    var p = parser.Parser.init(allocator, src);
    var program = try p.parse();
    defer program.deinit();

    // Codegen
    const output = try x64gen.generate(allocator, program);
    defer allocator.free(output.code);

    // PE wrap
    const pe_bytes = try pe.write(allocator, output.code, output.import_dir_rva, output.idat_size);
    defer allocator.free(pe_bytes);

    // Write output
    const out_path = output_path orelse blk: {
        const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
        const base = input_path[0..ext_idx];
        break :blk try std.fmt.allocPrint(allocator, "{s}.exe", .{base});
    };
    defer if (output_path == null) allocator.free(out_path);

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = pe_bytes });

    // Run if requested
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
