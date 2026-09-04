const std = @import("std");
const ast = @import("compiler/frontend/ast.zig");
const parser = @import("compiler/frontend/parser/parser.zig");
const pe = @import("compiler/backend/object/pe/pe.zig");
const coff = @import("compiler/backend/object/coff/coff.zig");
const test_runner = @import("tools/test_runner/test_runner.zig");
const sema_mod = @import("compiler/frontend/sema/sema.zig");
const type_sys = @import("compiler/frontend/type_system/type_system.zig");
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

const safety = @import("compiler/safety/safety.zig");
const ver_pipeline = @import("compiler/middle/pipeline/pipeline.zig");
const settings = @import("compiler/settings.zig");
const minrt_obj_bytes = @embedFile("runtime/minrt.obj");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Leak reports suppressed — BIR/MIR data structures are intentionally
    // not freed; the OS reclaims all memory at process exit.
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 and !(args.len == 2 and std.mem.eql(u8, args[1], "doctor"))) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: bpc build <pipeline.b+> [-o <output_dir>]\n");
        try stderr.writeAll("       bpc dll   <input.b+> [-o <output.dll>] [-exports <name1,name2,...>]\n");
        try stderr.writeAll("       bpc run   <input.b+>\n");
        try stderr.writeAll("       bpc test  <test.bpt>\n");
        try stderr.writeAll("       bpc hlsl  <input.b+> [-o <output.hlsl>]\n");
        try stderr.writeAll("       bpc ir    <pipeline.b+>\n");
        try stderr.writeAll("       bpc cfg   <pipeline.b+>\n");
        try stderr.writeAll("       bpc dom   <pipeline.b+>\n");
        try stderr.writeAll("       bpc loops <pipeline.b+>\n");
        try stderr.writeAll("       bpc bpl   <input.b+>\n");
        try stderr.writeAll("       bpc mir   <input.b+>        B+ source to COFF .obj\n");
        try stderr.writeAll("       bpc link  <input.obj> -o <output.exe>\n");
        try stderr.writeAll("       bpc check <input.b+>        verify all IR layers without codegen\n");
        try stderr.writeAll("       bpc doctor                  compiler health check\n");
        std.process.exit(1);
    }

    const command = args[1];
    const input_path: []const u8 = if (args.len > 2) args[2] else "";

    if (std.mem.eql(u8, command, "doctor")) {
        return doctorRun(allocator);
    }
    if (std.mem.eql(u8, command, "check")) {
        return checkRun(allocator, input_path);
    }

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
            } else if (std.mem.eql(u8, args[i], "--debug-ir")) {
                settings.debug_ir = true;
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
        const stdout = std.io.getStdOut().writer();
        const desc = test_runner.parseTestDesc(allocator, test_text) catch |err| {
            if (err == error.ExpectedTestKeyword) {
                try stdout.print("error: no 'test \"name\":' section found in {s}\n", .{input_path});
                std.process.exit(1);
            }
            return err;
        };
        // Resolve source path relative to .bpt directory
        const source_full = try std.fs.path.join(allocator, &.{ dir, desc.source });
        defer allocator.free(source_full);

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

        var bir_module = try bir_bplus_frontend.lowerProgram(arena_alloc, &program);

        {
            var safety_result = try safety.runSafetyChecks(arena_alloc, &program, &bir_module);
            defer safety_result.deinit();
            if (safety_result.hasErrors()) {
                try safety.reportSafetyErrors(std.io.getStdErr().writer(), &safety_result);
                std.process.exit(1);
            }
        }

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

        // Dump MIR instructions per block
        // This is the path from main.zig pipeline, not used by bplus.zig

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

    // LINK mode: link a COFF object file into an executable
    if (std.mem.eql(u8, command, "link")) {
        const linker = @import("linker/linker.zig");

        const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
        const base = input_path[0..ext_idx];
        const out_path = output_path orelse try std.fmt.allocPrint(allocator, "{s}.exe", .{base});

        // Write embedded runtime object to a temp file
        const tmp_dir = std.fs.cwd();
        const rt_obj_name = ".bpc_minrt.obj";
        try tmp_dir.writeFile(.{ .sub_path = rt_obj_name, .data = minrt_obj_bytes });
        defer tmp_dir.deleteFile(rt_obj_name) catch {};

        try linker.link(allocator, .{
            .obj_path = input_path,
            .output_path = out_path,
        .entry = "bplus_start",
            .subsystem = "console",
            .libs = &.{"kernel32.lib"},
            .extra_objs = &.{rt_obj_name},
        });

        // Link succeeded: drop the import library / .exp that lld-link may emit.
        const base_ext = std.mem.lastIndexOfScalar(u8, out_path, '.') orelse out_path.len;
        std.fs.cwd().deleteFile(try std.fmt.allocPrint(allocator, "{s}.lib", .{out_path[0..base_ext]})) catch {};
        std.fs.cwd().deleteFile(try std.fmt.allocPrint(allocator, "{s}.exp", .{out_path[0..base_ext]})) catch {};

        const stdout = std.io.getStdOut().writer();
        try stdout.print("Linked: {s} -> {s}\n", .{ input_path, out_path });
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

        {
            var safety_result = try safety.runSafetyChecks(arena_alloc, &program, &module);
            defer safety_result.deinit();
            if (safety_result.hasErrors()) {
                try safety.reportSafetyErrors(std.io.getStdErr().writer(), &safety_result);
            }
        }

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
    const is_run = std.mem.eql(u8, command, "run");

    // For .b+ files: use bir_bplus_frontend path (B+ native syntax: x = 10 without var)
    const is_bplus_file = std.mem.endsWith(u8, input_path, ".b+");
    if (is_bplus_file and (is_run or is_dll)) {
        var bir_module = try bir_bplus_frontend.lowerProgram(allocator, &program);

        const mfuncs = try bir_cpu.lowerModuleToMir(allocator, &bir_module);

        var mir_funcs_list = std.ArrayList(mir.MFunction).init(allocator);
        try mir_funcs_list.appendSlice(mfuncs);
        _ = mir.MModule{ .functions = mir_funcs_list, .allocator = allocator };
        const coff_result = try coff.emitCoff(mfuncs);
        defer coff_result.bytes.deinit();

        const ext = if (is_dll) "dll" else "exe";
        const out_path_result = output_path orelse blk: {
            const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
            const base = input_path[0..ext_idx];
            break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, ext });
        };
        defer if (output_path == null) allocator.free(out_path_result);

        const tmp_dir = std.fs.cwd();
        const obj_name = try std.fmt.allocPrint(allocator, ".bpc_{s}.obj", .{std.fs.path.stem(input_path)});
        defer allocator.free(obj_name);
        try tmp_dir.writeFile(.{ .sub_path = obj_name, .data = coff_result.bytes.items });

        const rt_obj_name = ".bpc_minrt.obj";
        try tmp_dir.writeFile(.{ .sub_path = rt_obj_name, .data = minrt_obj_bytes });

        const linker = @import("linker/linker.zig");
        try linker.link(allocator, .{
            .obj_path = obj_name,
            .output_path = out_path_result,
            .entry = "bplus_start",
            .subsystem = "console",
            .mode = if (is_dll) .dll else .exe,
            .libs = &.{"kernel32.lib"},
            .extra_objs = &.{rt_obj_name},
        });

        _ = tmp_dir.deleteFile(obj_name) catch {};
        _ = tmp_dir.deleteFile(rt_obj_name) catch {};

        const stdout = std.io.getStdOut().writer();
        try stdout.print("Built: {s}\n", .{out_path_result});

        if (is_run) {
            const run_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{out_path_result},
            }) catch |err| {
                std.log.err("failed to run: {}", .{err});
                std.process.exit(1);
            };
            defer allocator.free(run_result.stdout);
            defer allocator.free(run_result.stderr);
            try std.io.getStdOut().writeAll(run_result.stdout);
            if (run_result.stderr.len > 0) {
                try std.io.getStdErr().writeAll(run_result.stderr);
            }
        }
        return;
    }

    // Verified pipeline: HIR → THIR → BIR(SSA) → MIR → COFF → link → PE/DLL
    var type_engine = type_sys.TypeEngine.init(allocator);
    defer type_engine.deinit();

    var pipeline_result = try ver_pipeline.runFullVerifiedPipeline(allocator, &program, &sema_result_main, &type_engine);
    defer {
        pipeline_result.verified_machine.deinit();
        pipeline_result.verified_mir.deinit();
        pipeline_result.verified_bir.deinit();
    }

    const mfuncs = pipeline_result.verified_mir.getModule().functions.items;
    if (mfuncs.len == 0) {
        std.log.err("pipeline produced no functions: PLAN state machines are not yet lowered through the new pipeline.", .{});
        std.process.exit(1);
    }
    const coff_result = try coff.emitCoff(mfuncs);
    defer coff_result.bytes.deinit();

    const ext = if (is_dll) "dll" else "exe";
    const out_path = output_path orelse blk: {
        const ext_idx = std.mem.lastIndexOfScalar(u8, input_path, '.') orelse input_path.len;
        const base = input_path[0..ext_idx];
        break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, ext });
    };
    defer if (output_path == null) allocator.free(out_path);

    // Write COFF to temp file
    const tmp_dir = std.fs.cwd();
    const obj_name = try std.fmt.allocPrint(allocator, ".bpc_{s}.obj", .{std.fs.path.stem(input_path)});
    defer allocator.free(obj_name);
    try tmp_dir.writeFile(.{ .sub_path = obj_name, .data = coff_result.bytes.items });

    // Write embedded runtime object
    const rt_obj_name = ".bpc_minrt.obj";
    try tmp_dir.writeFile(.{ .sub_path = rt_obj_name, .data = minrt_obj_bytes });

    // Link with lld-link (EXE or DLL)
    const linker = @import("linker/linker.zig");
    try linker.link(allocator, .{
        .obj_path = obj_name,
        .output_path = out_path,
        .entry = "bplus_start",
        .subsystem = "console",
        .mode = if (is_dll) .dll else .exe,
        .libs = &.{"kernel32.lib"},
        .extra_objs = &.{rt_obj_name},
    });

    // Clean up temp artifacts
    const base_ext = std.mem.lastIndexOfScalar(u8, out_path, '.') orelse out_path.len;
    const lib_path = try std.fmt.allocPrint(allocator, "{s}.lib", .{out_path[0..base_ext]});
    defer allocator.free(lib_path);
    const exp_path = try std.fmt.allocPrint(allocator, "{s}.exp", .{out_path[0..base_ext]});
    defer allocator.free(exp_path);
    tmp_dir.deleteFile(obj_name) catch {};
    tmp_dir.deleteFile(rt_obj_name) catch {};
    std.fs.cwd().deleteFile(lib_path) catch {};
    std.fs.cwd().deleteFile(exp_path) catch {};

    if (is_run) {
        var child = std.process.Child.init(&[_][]const u8{ out_path }, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        // Mark launch so the runtime wrapper does not pause for a key.
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        try env.put("BPC_RUN", "1");
        child.env_map = &env;
        const term = try child.spawnAndWait();
        std.process.exit(switch (term) {
            .Exited => |code| code,
            else => 1,
        });
    }
}

const StageReporter = struct {
    stdout: std.fs.File.Writer,
    failed: bool = false,
};

fn reportStageCb(ctx: *anyopaque, stage: []const u8) void {
    const self: *StageReporter = @ptrCast(@alignCast(ctx));
    if (self.failed) return;
    self.stdout.print("{s:<12} PASS\n", .{stage}) catch {};
}

fn checkRun(allocator: std.mem.Allocator, input_path: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var src = std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(u32)) catch |err| {
        try stdout.print("bpc check: cannot read {s}: {s}\n", .{ input_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(src);
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) {
        const stripped = try allocator.dupe(u8, src[3..]);
        allocator.free(src);
        src = stripped;
    }

    var p = parser.Parser.init(allocator, src, input_path);
    var program = p.parse() catch |err| {
        try stdout.print("FAIL: parse error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer program.deinit();

    try stdout.print("B+ check: {s}\n", .{input_path});
    try stdout.print("{s:<12} ", .{"Parser"});
    const sema_result = sema_mod.analyze(allocator, program, src, input_path) catch |err| {
        try stdout.print("FAIL: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer sema_result.deinit();
    try stdout.print("PASS\n", .{});

    var type_engine = type_sys.TypeEngine.init(allocator);
    defer type_engine.deinit();

    var reporter = StageReporter{ .stdout = stdout };
    const cr = ver_pipeline.CheckReporter{ .ctx = &reporter, .reportFn = reportStageCb };
    var pipeline_result = ver_pipeline.runFullVerifiedPipelineReport(allocator, &program, &sema_result, &type_engine, &cr) catch |err| {
        reporter.failed = true;
        try stdout.print("FAIL: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer {
        pipeline_result.verified_machine.deinit();
        pipeline_result.verified_mir.deinit();
        pipeline_result.verified_bir.deinit();
    }
    try stdout.print("OK: all layers verified\n", .{});
}

fn doctorRun(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("B+ Compiler Health Check\n", .{});
    try stdout.print("-------------------------\n", .{});

    var all_ok = true;

    if (minrt_obj_bytes.len > 0) {
        try stdout.print("{s:<12} PASS\n", .{"Runtime"});
    } else {
        all_ok = false;
        try stdout.print("{s:<12} FAIL (empty minrt.obj)\n", .{"Runtime"});
    }

    const lld_path = "C:\\Program Files\\LLVM\\bin\\lld-link.exe";
    if (std.fs.accessAbsolute(lld_path, .{})) |_| {
        try stdout.print("{s:<12} PASS\n", .{"Linker"});
    } else |_| {
        all_ok = false;
        try stdout.print("{s:<12} FAIL (not found: {s})\n", .{ "Linker", lld_path });
    }

    const self_src = "fn main() { print(\"ok\") }\n";
    const src = try allocator.dupe(u8, self_src);
    defer allocator.free(src);
    const input_path = "<doctor>";

    var p = parser.Parser.init(allocator, src, input_path);
    var program = p.parse() catch |err| {
        try stdout.print("FAIL: parse error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer program.deinit();

    try stdout.print("{s:<12} ", .{"Parser"});
    const sema_result = sema_mod.analyze(allocator, program, src, input_path) catch |err| {
        all_ok = false;
        try stdout.print("FAIL: {s}\n", .{@errorName(err)});
        try stdout.print("Compiler stability: {s}\n", .{"BROKEN"});
        std.process.exit(1);
    };
    defer sema_result.deinit();
    try stdout.print("PASS\n", .{});

    var type_engine = type_sys.TypeEngine.init(allocator);
    defer type_engine.deinit();

    var reporter = StageReporter{ .stdout = stdout };
    const cr = ver_pipeline.CheckReporter{ .ctx = &reporter, .reportFn = reportStageCb };
    var pipeline_result = ver_pipeline.runFullVerifiedPipelineReport(allocator, &program, &sema_result, &type_engine, &cr) catch |err| {
        all_ok = false;
        reporter.failed = true;
        try stdout.print("FAIL: {s}\n", .{@errorName(err)});
        try stdout.print("Compiler stability: {s}\n", .{"BROKEN"});
        std.process.exit(1);
    };
    defer {
        pipeline_result.verified_machine.deinit();
        pipeline_result.verified_mir.deinit();
        pipeline_result.verified_bir.deinit();
    }

    if (all_ok) {
        try stdout.print("Compiler stability: OK\n", .{});
    } else {
        try stdout.print("Compiler stability: WARNING\n", .{});
        std.process.exit(1);
    }
}
