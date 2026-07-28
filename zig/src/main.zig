const std = @import("std");
const ast = @import("compiler/frontend/ast.zig");
const parser = @import("compiler/frontend/parser/parser.zig");
const x64gen = @import("compiler/backend/targets/x64/x64gen.zig");
const pe = @import("compiler/backend/object/pe/pe.zig");
const coff = @import("compiler/backend/object/coff/coff.zig");
const test_runner = @import("tools/test_runner/test_runner.zig");
const sema_mod = @import("compiler/frontend/sema/sema.zig");
const gpu_ir = @import("compiler/gpu/gpu_ir.zig");
const bir = @import("compiler/middle/bir/bir.zig");
const bir_frontend = @import("compiler/middle/bir/bir_frontend.zig");
const bir_passes = @import("compiler/middle/bir/passes/manager.zig");
const bir_lower = @import("compiler/middle/bir/lowering/lower.zig");
const bir_cfg = @import("compiler/middle/bir/bir_cfg.zig");
const bir_dominators = @import("compiler/middle/bir/analysis/dominator/dominator.zig");
const bir_loops = @import("compiler/middle/bir/analysis/loops/loops.zig");
const bir_hlsl = @import("compiler/middle/bir/bir_hlsl.zig");

const bir_bplus_frontend = @import("compiler/middle/bir/bir_bplus_frontend.zig");
const bir_cpu = @import("compiler/middle/bir/lowering/cpu.zig");
const bir_lower_dump = @import("compiler/middle/bir/lowering/lower.zig");
const mir = @import("compiler/backend/mir/mir.zig");
const machine = @import("compiler/backend/machine/machine.zig");
const mir_lower = machine.mir_lower;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: bpc build <pipeline.b+> [-o <output_dir>]\n");
        try stderr.writeAll("       bpc dll   <input.b+> [-o <output.dll>] [-exports <name1,name2,...>]\n");
        try stderr.writeAll("       bpc run   <input.b+>\n");
        try stderr.writeAll("       bpc test  <test.bpt>\n");
        try stderr.writeAll("       bpc hlsl  <input.b+> [-o <output.hlsl>]\n");
        try stderr.writeAll("       bpc gpu   <input.b+> [-o <output>]\n");
        try stderr.writeAll("       bpc ir    <pipeline.b+>\n");
        try stderr.writeAll("       bpc cfg   <pipeline.b+>\n");
        try stderr.writeAll("       bpc dom   <pipeline.b+>\n");
        try stderr.writeAll("       bpc loops <pipeline.b+>\n");
        try stderr.writeAll("       bpc bpl   <input.b+>\n");
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

    // C++ mode: generate C++ from B+
    if (std.mem.eql(u8, command, "cpp")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const trimmed = std.mem.trim(u8, src, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "kernel ")) {
            // GPU kernel → UE C++ shader class via gpu_cpp
            try gpuCompileAndWrite(arena_alloc, src, input_path, output_path, .cpp);
        } else {
            // General B+ → full C++ via cppgen
            const cppgen = @import("compiler/frontend/cppgen.zig");
            var p = parser.Parser.init(arena_alloc, src, input_path);
            const program = try p.parse();
            const output = try cppgen.generate(arena_alloc, program);
            const out_path = output_path orelse blk: {
                const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
                const base = input_path[0..ext_idx];
                break :blk try std.fmt.allocPrint(arena_alloc, "{s}.cpp", .{base});
            };
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output.text });
            const stdout = std.io.getStdOut().writer();
            try stdout.print("C++ written to {s}\n", .{out_path});
        }
        return;
    }

    // HLSL mode: generate HLSL shader text
    if (std.mem.eql(u8, command, "hlsl")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Auto-detect GPU kernel syntax
        const trimmed = std.mem.trim(u8, src, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "kernel ")) {
            try gpuCompileAndWrite(arena_alloc, src, input_path, output_path, .hlsl);
            return;
        }

        // Pipeline description → BIR → HLSL
        {
            const pipeline_gen_m = @import("compiler/backend/mir/pipeline_gen.zig");
            const pipeline = pipeline_gen_m.parsePipeline(arena_alloc, src) catch {
                // Old hlslgen fallback removed — use BIR pipeline
                const stderr = std.io.getStdErr().writer();
                try stderr.writeAll("Pipeline parse failed and legacy HLSLgen is removed. Use BIR pipeline.\n");
                std.process.exit(1);
            };
        var module = try bir_lower.lowerPipeline(arena_alloc, &pipeline);
        var am = bir.AnalysisManager.init(arena_alloc, &module);
        defer am.deinit();
        var ctx = bir.PassContext{
            .module = &module,
            .analysis = &am,
            .allocator = arena_alloc,
        };
        var pm = bir_passes.StandardPasses.init(arena_alloc);
        try pm.run(&ctx);
            const output = try bir_hlsl.generateHlsl(arena_alloc, &module);
            const out_path = output_path orelse blk: {
                const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
                const base = input_path[0..ext_idx];
                break :blk try std.fmt.allocPrint(arena_alloc, "{s}.hlsl", .{base});
            };
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output });
            const stdout = std.io.getStdOut().writer();
            try stdout.print("BIR→HLSL written to {s}\n", .{out_path});
            return;
        }
    }

    // IR mode: lower pipeline to BIR and dump it
    if (std.mem.eql(u8, command, "ir")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const pipeline_gen_m = @import("compiler/backend/mir/pipeline_gen.zig");
        const pipeline = try pipeline_gen_m.parsePipeline(arena_alloc, src);

        var module = try bir_lower.lowerPipeline(arena_alloc, &pipeline);
        var am = bir.AnalysisManager.init(arena_alloc, &module);
        defer am.deinit();
        var ctx = bir.PassContext{
            .module = &module,
            .analysis = &am,
            .allocator = arena_alloc,
        };
        var pm = bir_passes.StandardPasses.init(arena_alloc);
        try pm.run(&ctx);

        const stdout = std.io.getStdOut().writer();
        try bir_lower.dumpModule(&module, stdout);
        return;
    }

    // CFG mode: dump control flow graph for pipeline
    if (std.mem.eql(u8, command, "cfg")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const pipeline_gen_m = @import("compiler/backend/mir/pipeline_gen.zig");
        const pipeline = try pipeline_gen_m.parsePipeline(arena_alloc, src);

        var module = try bir_lower.lowerPipeline(arena_alloc, &pipeline);
        var am = bir.AnalysisManager.init(arena_alloc, &module);
        defer am.deinit();
        var ctx = bir.PassContext{
            .module = &module,
            .analysis = &am,
            .allocator = arena_alloc,
        };
        var pm = bir_passes.StandardPasses.init(arena_alloc);
        try pm.run(&ctx);

        const stdout = std.io.getStdOut().writer();
        for (module.functions.items) |*func| {
            try stdout.print("; Function: {s}\n", .{func.name});
            var cfg = try bir_cfg.buildCFG(arena_alloc, func);
            defer cfg.deinit();
            try bir_cfg.dumpCFG(&cfg, func, stdout);
        }
        return;
    }

    // DOM mode: dump dominator tree for pipeline
    if (std.mem.eql(u8, command, "dom")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const pipeline_gen_m = @import("compiler/backend/mir/pipeline_gen.zig");
        const pipeline = try pipeline_gen_m.parsePipeline(arena_alloc, src);

        var module = try bir_lower.lowerPipeline(arena_alloc, &pipeline);
        var am = bir.AnalysisManager.init(arena_alloc, &module);
        defer am.deinit();
        var ctx = bir.PassContext{
            .module = &module,
            .analysis = &am,
            .allocator = arena_alloc,
        };
        var pm = bir_passes.StandardPasses.init(arena_alloc);
        try pm.run(&ctx);

        const stdout = std.io.getStdOut().writer();
        for (module.functions.items) |*func| {
            try stdout.print("; Function: {s}\n", .{func.name});
            var cfg = try bir_cfg.buildCFG(arena_alloc, func);
            defer cfg.deinit();
            try bir_cfg.dumpCFG(&cfg, func, stdout);
        }
        return;
    }

    // LOOPS mode: dump loop hierarchy
    if (std.mem.eql(u8, command, "loops")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const pipeline_gen_m = @import("compiler/backend/mir/pipeline_gen.zig");
        const pipeline = try pipeline_gen_m.parsePipeline(arena_alloc, src);

        var module = try bir_lower.lowerPipeline(arena_alloc, &pipeline);
        var am = bir.AnalysisManager.init(arena_alloc, &module);
        defer am.deinit();
        var ctx = bir.PassContext{
            .module = &module,
            .analysis = &am,
            .allocator = arena_alloc,
        };
        var pm = bir_passes.StandardPasses.init(arena_alloc);
        try pm.run(&ctx);

        const stdout = std.io.getStdOut().writer();
        for (module.functions.items) |*func| {
            try stdout.print("; Function: {s}\n", .{func.name});
            var cfg = try bir_cfg.buildCFG(arena_alloc, func);
            defer cfg.deinit();
            var dt = try bir_dominators.buildDominators(arena_alloc, &cfg, func);
            defer dt.deinit();
            const loops = try bir_loops.findLoops(arena_alloc, &cfg, func, &dt);
            try stdout.print("; {d} loops found\n", .{loops.loops.len});
        }
        return;
    }

    // MIR mode: B+ source → BIR → MIR → x64 COFF object
    if (std.mem.eql(u8, command, "mir")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var p = parser.Parser.init(arena_alloc, src, input_path);
        var program = try p.parse();
        const sema_result = sema_mod.analyze(arena_alloc, program, src, input_path) catch |err| {
            std.log.err("semantic analysis failed: {}", .{err});
            std.process.exit(1);
        };
        defer sema_result.deinit();

        const bir_module = try bir_bplus_frontend.lowerProgram(arena_alloc, &program);
        const mfuncs = try bir_cpu.lowerModuleToMir(arena_alloc, &bir_module);

        // Wrap in MIR module for Machine IR lowering
        var mir_funcs_list = std.ArrayList(mir.MFunction).init(arena_alloc);
        try mir_funcs_list.appendSlice(mfuncs);
        var mir_mod = mir.MModule{ .functions = mir_funcs_list, .allocator = arena_alloc };
        const mach_mod = try mir_lower.lowerModule(&mir_mod, arena_alloc);

        // Dump Machine IR
        {
            const stdout = std.io.getStdOut().writer();
            for (mach_mod.functions.items) |mach_func| {
                try stdout.print("; Machine IR: {s}\n", .{mach_func.name});
                for (mach_func.blocks.items) |blk| {
                    try stdout.print("  {s}:\n", .{blk.name});
                    for (blk.instrs.items) |inst| {
                        try stdout.print("    {s}\n", .{@tagName(inst)});
                    }
                }
            }
        }

        const coff_result = try coff.emitCoff(mfuncs);
        defer coff_result.bytes.deinit();

        const out_path = output_path orelse blk: {
            const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
            const base = input_path[0..ext_idx];
            break :blk try std.fmt.allocPrint(arena_alloc, "{s}.obj", .{base});
        };
        try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = coff_result.bytes.items });
        const stdout = std.io.getStdOut().writer();
        try stdout.print("COFF object written to {s}\n", .{out_path});
        try stdout.print("  functions: {d}\n", .{mfuncs.len});
        return;
    }

    // BPL mode: lower B+ source to BIR and dump
    if (std.mem.eql(u8, command, "bpl")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var p = parser.Parser.init(arena_alloc, src, input_path);
        var program = try p.parse();
        defer program.deinit();

        const sema_result_bpl = sema_mod.analyze(arena_alloc, program, src, input_path) catch |err| {
            std.log.err("semantic analysis failed: {}", .{err});
            std.process.exit(1);
        };
        defer sema_result_bpl.deinit();

        var module = try bir_bplus_frontend.lowerProgram(arena_alloc, &program);
        defer module.deinit();

        const stdout = std.io.getStdOut().writer();
        try bir_lower_dump.dumpModule(&module, stdout);
        return;
    }

    // Build mode: generate C++ UE5 plugin code from pipeline description
    if (std.mem.eql(u8, command, "build")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const pipeline_gen = @import("compiler/backend/mir/pipeline_gen.zig");
        const pipeline = try pipeline_gen.parsePipeline(arena_alloc, src);

        // Output dir = -o <dir> or same dir as input file
        const out_dir = if (output_path) |p| p else blk: {
            const last_slash = std.mem.lastIndexOfScalar(u8, input_path, '\\') orelse
                std.mem.lastIndexOfScalar(u8, input_path, '/') orelse 0;
            break :blk input_path[0..last_slash];
        };

        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("Pipeline '");
        try stdout.writeAll(pipeline.name);
        try stdout.writeAll("': generating C++ in '");
        try stdout.writeAll(out_dir);
        try stdout.writeAll("'...\n");

        const shaders_h = try pipeline_gen.generateShadersHeader(arena_alloc, &pipeline);
        const shaders_cpp = try pipeline_gen.generateShadersCpp(arena_alloc, &pipeline);
        const runtime_h = try pipeline_gen.generateRuntimeHeader(arena_alloc, &pipeline);
        const runtime_cpp = try pipeline_gen.generateRuntimeCpp(arena_alloc, &pipeline);
        const viewext_h = try pipeline_gen.generateViewExtensionHeader(arena_alloc, &pipeline);
        const viewext_cpp = try pipeline_gen.generateViewExtensionCpp(arena_alloc, &pipeline);

        const file_infos = [_]struct { []const u8, []const u8 }{
            .{ "TSSShaders.h", shaders_h },
            .{ "TSSShaders.cpp", shaders_cpp },
            .{ "TSSRuntime.h", runtime_h },
            .{ "TSSRuntime.cpp", runtime_cpp },
            .{ "TSSViewExtension.h", viewext_h },
            .{ "TSSViewExtension.cpp", viewext_cpp },
        };
        for (file_infos) |pair| {
            const full_path = try std.fs.path.join(arena_alloc, &.{ out_dir, pair.@"0" });
            try std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = pair.@"1" });
            try stdout.writeAll("  wrote ");
            try stdout.writeAll(full_path);
            try stdout.writeAll("\n");
        }

        try stdout.writeAll("Done. Pipeline '");
        try stdout.writeAll(pipeline.name);
        try stdout.writeAll("' built: 6 files.\n");
        return;
    }

    // GPU mode: parse GPU kernel and generate HLSL via parser.zig
    if (std.mem.eql(u8, command, "gpu")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        try gpuCompileAndWrite(arena_alloc, src, input_path, output_path, .dxil);
        return;
    }

    var p = parser.Parser.init(allocator, src, input_path);
    var program = try p.parse();
    defer program.deinit();

    // ── Semantic analysis pass ──
    const sema_result_main = sema_mod.analyze(allocator, program, src, input_path) catch |err| {
        std.log.err("semantic analysis failed: {}", .{err});
        std.process.exit(1);
    };
    defer sema_result_main.deinit();

    const is_dll = std.mem.eql(u8, command, "dll");

    // Mark entries as exports based on -exports flag
    if (is_dll) {
        if (export_names) |names| {
            var it = std.mem.splitScalar(u8, names, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " \t");
                for (program.metal.entries.items) |*e| {
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

fn gpuCompileAndWrite(arena_alloc: std.mem.Allocator, src: []const u8, input_path: []const u8, output_path_arg: ?[]const u8, target: gpu_ir.BackendType) !void {
    var p = parser.Parser.init(arena_alloc, src, input_path);
    const kernel = p.parseGpuKernelBlock() catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("GPU parse error: {}\n", .{err});
        std.process.exit(1);
    };

    var gpu_mod = gpu_ir.GpuModule{
        .allocator = arena_alloc,
        .kernels = std.ArrayList(gpu_ir.GpuKernel).init(arena_alloc),
    };
    try gpu_mod.kernels.append(kernel);

    // BIR path for HLSL
    if (target == .hlsl) {
        var bir_mod = try bir_frontend.lowerToBir(arena_alloc, &gpu_mod);
        defer bir_mod.deinit();

        var am = bir.AnalysisManager.init(arena_alloc, &bir_mod);
        defer am.deinit();
        var ctx = bir.PassContext{
            .module = &bir_mod,
            .analysis = &am,
            .allocator = arena_alloc,
        };
        var pm = bir_passes.StandardPasses.init(arena_alloc);
        try pm.run(&ctx);

        const output = try bir_hlsl.generateHlsl(arena_alloc, &bir_mod);
        const out_path = output_path_arg orelse blk: {
            const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
            const base = input_path[0..ext_idx];
            break :blk try std.fmt.allocPrint(arena_alloc, "{s}.hlsl", .{base});
        };
        try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output });
        const stdout = std.io.getStdOut().writer();
        try stdout.print("BIR→HLSL written to {s}\n", .{out_path});
        return;
    }

    // DXIL/C++ backends — TODO: rewrite without gpu_lower
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll("DXIL/C++ backends not yet ported to unified pipeline.\n");
    std.process.exit(1);
}
