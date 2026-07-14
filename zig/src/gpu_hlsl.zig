const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ast = @import("gpu_ast.zig");
const gpu_ir = @import("gpu_ir.zig");

/// Generate HLSL directly from GPU AST (legacy path)
pub fn generateHlsl(allocator: Allocator, module: *const gpu_ast.GpuModule) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    for (module.kernels.items) |kernel| {
        for (kernel.resources.items) |res| {
            try emitResourceDecl(w, &res);
        }
        try w.writeAll("\n");

        if (kernel.cbuffer_members.items.len > 0) {
            try emitCbufferDecl(w, kernel.cbuffer_members.items);
            try w.writeAll("\n");
        }

        for (kernel.entries.items) |entry| {
            try w.print("[numthreads({}, {}, {})]\n", .{ entry.numthreads.x, entry.numthreads.y, entry.numthreads.z });
            try w.print("void {s}(uint3 __tid : SV_DispatchThreadID)", .{entry.name});
            try w.writeAll("{\n");
            try w.print("    uint {s} = __tid.x;\n", .{entry.x_param});
            try w.print("    uint {s} = __tid.y;\n", .{entry.y_param});
            for (entry.body_lines.items) |line| {
                try w.print("    {s}\n", .{ line });
            }
            try w.writeAll("}\n");
        }
    }

    return buf.toOwnedSlice();
}

/// Generate HLSL from GPU IR (Phase 4 pipeline)
pub fn generateHlslFromIr(allocator: Allocator, ir: *const gpu_ir.IrModule) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll("#include \"/Engine/Public/Platform.ush\"\n");
    try w.writeAll("\n");

    for (ir.resources.items) |res| {
        try emitIrResourceDecl(w, &res);
    }
    try w.writeAll("\n");

    if (ir.cbuffer_members.items.len > 0) {
        try emitIrCbuffer(w, ir.cbuffer_members.items);
        try w.writeAll("\n");
    }

    var declared_names = std.StringHashMap(void).init(allocator);
    defer {
        var rit = declared_names.keyIterator();
        while (rit.next()) |k| allocator.free(k.*);
        declared_names.deinit();
    }
    for (ir.resources.items) |res| {
        const name = try allocator.dupe(u8, res.name);
        try declared_names.put(name, {});
    }
    for (ir.cbuffer_members.items) |mem| {
        if (!declared_names.contains(mem.name)) {
            const name = try allocator.dupe(u8, mem.name);
            try declared_names.put(name, {});
        }
    }

    for (ir.functions.items) |func| {
        for (func.globals_lines.items) |line| {
            try w.print("{s}\n", .{line});
        }

        try w.print("[numthreads({}, {}, {})]\n", .{ func.numthreads.x, func.numthreads.y, func.numthreads.z });
        const entry_name = try std.fmt.allocPrint(allocator, "{s}Main", .{func.kernel_name});
        try w.print("void {s}(uint3 __tid : SV_DispatchThreadID)", .{entry_name});
        try w.writeAll("{\n");
        try w.print("    uint {s} = __tid.x;\n", .{func.x_param});
        try w.print("    uint {s} = __tid.y;\n", .{func.y_param});

        for (func.locals.items) |local| {
            const lt = typeRefToHlslType(local.type_ref);
            try w.print("    {s} {s}", .{ lt, local.name });
            for (local.array_dims) |dim| {
                try w.print("[{d}]", .{dim});
            }
            try w.writeAll(";\n");
            const name = try allocator.dupe(u8, local.name);
            try declared_names.put(name, {});
        }

        if (func.passthrough_body.items.len > 0) {
            for (func.passthrough_body.items) |line| {
                try w.print("    {s}\n", .{ line });
            }
        } else {
            try emitIrFunctionBody(w, allocator, &func, &declared_names);
        }

        try w.writeAll("}\n");
    }

    return buf.toOwnedSlice();
}

const ForLoopInfo = struct {
    header_idx: usize,
    body_idx: usize,
    continue_idx: usize,
    exit_idx: usize,
};

fn scanForLoops(func: *const gpu_ir.IrFunction, allocator: Allocator) !std.AutoHashMap(usize, ForLoopInfo) {
    var loops = std.AutoHashMap(usize, ForLoopInfo).init(allocator);
    for (func.blocks.items, 0..) |*block, idx| {
        if (!std.mem.eql(u8, block.label, "for.header")) continue;
        if (block.instrs.items.len == 0) continue;
        const last = block.instrs.getLast();
        if (last.op != .branch) continue;
        const cb = last.data.cond_branch;
        const body_idx = cb.then_block;
        const exit_idx = cb.else_block;
        var continue_idx: ?usize = null;
        for (func.blocks.items, 0..) |*other, oidx| {
            if (other.instrs.items.len == 0) continue;
            const last2 = other.instrs.getLast();
            if (last2.op == .ret and last2.data == .block_target and last2.data.block_target == idx) {
                continue_idx = oidx;
            }
        }
        if (continue_idx) |ci| {
            try loops.put(idx, ForLoopInfo{ .header_idx = idx, .body_idx = body_idx, .continue_idx = ci, .exit_idx = exit_idx });
        }
    }
    return loops;
}

fn emitInst(w: anytype, func: *const gpu_ir.IrFunction, var_names: *std.AutoHashMap(gpu_ir.ValueId, []const u8), resource_names: *const std.StringHashMap(void), inst: *const gpu_ir.IrInst) !void {
    const name_owned = var_names.get(inst.result).?;
    const t = typeRefToHlslType(inst.ty);
    switch (inst.op) {
        .phi, .branch, .ret, .loop => return,
        .@"const" => {
            try w.print("    {s}", .{name_owned});
            switch (inst.ty) {
                .f32, .vec2f, .vec3f, .vec4f, .f16 => try w.print(" = {d}", .{inst.data.float_val}),
                else => try w.print(" = {d}", .{inst.data.int_val}),
            }
        },
        .load => {
            if (resource_names.contains(inst.data.string) or isArrayLocal(func.locals, inst.data.string)) return;
            try w.print("    {s} = {s}", .{ name_owned, inst.data.string });
        },
        .store => {
            const base = if (inst.data == .string and inst.data.string.len > 0) inst.data.string else var_names.get(inst.operands[0]).?;
            try w.print("    {s}", .{base});
            for (inst.operands[1..inst.operands.len - 1]) |idx_op| try w.print("[{s}]", .{var_names.get(idx_op).?});
            try w.writeAll(" = ");
            try w.writeAll(var_names.get(inst.operands[inst.operands.len - 1]).?);
        },
        .add => try w.print("    {s} = {s} + {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .sub => try w.print("    {s} = {s} - {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .mul => try w.print("    {s} = {s} * {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .div => try w.print("    {s} = {s} / {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .mod => try w.print("    {s} = {s} % {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .call => {
            if (std.mem.eql(u8, inst.data.call_info.callee, "@array_get")) {
                try w.print("    {s} = {s}[{s}]", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? });
            } else if (inst.ty == .void) {
                if (isIntrinsicMethod(inst.data.call_info.callee) and inst.data.call_info.args.len >= 1) {
                    try w.print("    {s}.{s}(", .{ var_names.get(inst.data.call_info.args[0]).?, inst.data.call_info.callee });
                    for (inst.data.call_info.args[1..], 0..) |arg, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(var_names.get(arg).?);
                    }
                } else {
                    try w.print("    {s}(", .{inst.data.call_info.callee});
                    for (inst.data.call_info.args, 0..) |arg, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(var_names.get(arg).?);
                    }
                }
                try w.writeAll(")");
            } else {
                if (isIntrinsicMethod(inst.data.call_info.callee) and inst.data.call_info.args.len >= 1) {
                    try w.print("    {s} = {s}.{s}(", .{ name_owned, var_names.get(inst.data.call_info.args[0]).?, inst.data.call_info.callee });
                    for (inst.data.call_info.args[1..], 0..) |arg, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(var_names.get(arg).?);
                    }
                } else {
                    try w.print("    {s} = {s}(", .{ name_owned, inst.data.call_info.callee });
                    for (inst.data.call_info.args, 0..) |arg, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(var_names.get(arg).?);
                    }
                }
                try w.writeAll(")");
            }
        },
        .extract => {
            const swz = "xyzw"[inst.data.extract_info.index];
            try w.print("    {s} = {s}.{c}", .{ name_owned, var_names.get(inst.operands[0]).?, swz });
        },
        .composite => {
            try w.print("    {s} = {s}(", .{ name_owned, t });
            for (inst.operands, 0..) |op, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(var_names.get(op).?);
            }
            try w.writeAll(")");
        },
        .max => try w.print("    {s} = max({s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .min => try w.print("    {s} = min({s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .abs => try w.print("    {s} = abs({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .floor => try w.print("    {s} = floor({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .ceil => try w.print("    {s} = ceil({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .frac => try w.print("    {s} = frac({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .sin => try w.print("    {s} = sin({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .cos => try w.print("    {s} = cos({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .exp => try w.print("    {s} = exp({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .sqrt => try w.print("    {s} = sqrt({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .rsqrt => try w.print("    {s} = rsqrt({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .saturate => try w.print("    {s} = saturate({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .dot => try w.print("    {s} = dot({s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .fma => try w.print("    {s} = mad({s}, {s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).?, var_names.get(inst.operands[2]).? }),
        .lt => try w.print("    {s} = ({s}) < ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .le => try w.print("    {s} = ({s}) <= ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .gt => try w.print("    {s} = ({s}) > ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .ge => try w.print("    {s} = ({s}) >= ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .eq => try w.print("    {s} = ({s}) == ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .ne => try w.print("    {s} = ({s}) != ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .or_op => try w.print("    {s} = ({s}) || ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .and_op => try w.print("    {s} = ({s}) && ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
        .not => try w.print("    {s} = !({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .wave_read_lane_first => try w.print("    {s} = WaveReadLaneFirst({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .wave_get_lane_index => try w.print("    {s} = WaveGetLaneIndex()", .{name_owned}),
        .wave_is_first_lane => try w.print("    {s} = WaveIsFirstLane()", .{name_owned}),
        .wave_active_all_equal => try w.print("    {s} = WaveActiveAllEqual({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .quad_read_across_x => try w.print("    {s} = QuadReadAcrossX({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .quad_read_across_y => try w.print("    {s} = QuadReadAcrossY({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
        .select => try w.print("    {s} = {s} ? {s} : {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).?, var_names.get(inst.operands[2]).? }),
        .cast => {
            const to_type = typeRefToHlslType(inst.ty);
            try w.print("    {s} = ({s}){s}", .{ name_owned, to_type, var_names.get(inst.operands[0]).? });
        },
        .entry_point, .sample, .atomic, .barrier => {
            try w.print("    {s} = 0 /* unhandled op {s} */", .{ name_owned, @tagName(inst.op) });
        },
    }
    try w.writeAll(";\n");
}

fn emitForLoop(w: anytype, allocator: Allocator, func: *const gpu_ir.IrFunction, var_names: *std.AutoHashMap(gpu_ir.ValueId, []const u8), resource_names: *const std.StringHashMap(void), visited: *std.AutoHashMap(usize, void), for_loops: *const std.AutoHashMap(usize, ForLoopInfo), loop: ForLoopInfo) !void {
    _ = for_loops;
    const header = &func.blocks.items[loop.header_idx];
    var phi_incrs = std.ArrayList(struct { phi_val: gpu_ir.ValueId, incr_val: gpu_ir.ValueId }).init(allocator);
    defer phi_incrs.deinit();
    for (header.instrs.items) |*inst| {
        if (inst.op == .phi and inst.operands.len >= 2) {
            const name = var_names.get(inst.result).?;
            const init_name = var_names.get(inst.operands[0]).?;
            try w.print("    {s} = {s};\n", .{ name, init_name });
            try phi_incrs.append(.{ .phi_val = inst.result, .incr_val = inst.operands[1] });
        }
    }
    var cond_name: ?[]const u8 = null;
    try w.writeAll("    while (true) {\n");
    for (header.instrs.items) |*inst| {
        if (inst.op == .phi) {
        } else if (inst.op == .branch) {
            if (inst.operands.len > 0) {
                cond_name = var_names.get(inst.operands[0]).?;
            }
        } else {
            try emitInst(w, func, var_names, resource_names, inst);
        }
    }
    if (cond_name) |cn| try w.print("        if (!({s})) break;\n", .{cn});
    try visited.put(loop.body_idx, {});
    try visited.put(loop.continue_idx, {});
    try visited.put(loop.header_idx, {});
    const body_block = &func.blocks.items[loop.body_idx];
    for (body_block.instrs.items) |*inst| try emitInst(w, func, var_names, resource_names, inst);
    const cont_block = &func.blocks.items[loop.continue_idx];
    for (cont_block.instrs.items) |*inst| try emitInst(w, func, var_names, resource_names, inst);
    for (phi_incrs.items) |pv| {
        const name = var_names.get(pv.phi_val).?;
        const incr_name = var_names.get(pv.incr_val).?;
        try w.print("        {s} = {s};\n", .{ name, incr_name });
    }
    try w.writeAll("    }\n");
    if (!visited.contains(loop.exit_idx)) {
        try visited.put(loop.exit_idx, {});
        const exit_block = &func.blocks.items[loop.exit_idx];
        for (exit_block.instrs.items) |*inst| try emitInst(w, func, var_names, resource_names, inst);
    }
}

fn isArrayLocal(locals: std.ArrayList(gpu_ir.LocalDecl), name: []const u8) bool {
    for (locals.items) |local| {
        if (local.array_dims.len > 0 and std.mem.eql(u8, local.name, name)) return true;
    }
    return false;
}

fn emitIrFunctionBody(w: anytype, allocator: Allocator, func: *const gpu_ir.IrFunction, resource_names: *const std.StringHashMap(void)) !void {
    var var_names = std.AutoHashMap(gpu_ir.ValueId, []const u8).init(allocator);
    defer var_names.deinit();

    var next_temp: u32 = 0;

    for (func.blocks.items) |*block| {
        for (block.instrs.items) |*inst| {
            var name_buf: [16]u8 = undefined;
            if (inst.op == .load and (resource_names.contains(inst.data.string) or isArrayLocal(func.locals, inst.data.string))) {
                try var_names.put(inst.result, try allocator.dupe(u8, inst.data.string));
            } else {
                const name = try std.fmt.bufPrint(&name_buf, "_t{d}", .{next_temp});
                const name_owned = try allocator.dupe(u8, name);
                next_temp += 1;
                try var_names.put(inst.result, name_owned);
            }
        }
    }

    for (func.blocks.items) |*block| {
        for (block.instrs.items) |*inst| {
            if (inst.op == .branch or inst.op == .ret) continue;
            if (inst.op == .load and (resource_names.contains(inst.data.string) or isArrayLocal(func.locals, inst.data.string))) continue;
            const name_owned = var_names.get(inst.result).?;
            const t = typeRefToHlslType(inst.ty);
            try w.print("    {s} {s};\n", .{ t, name_owned });
        }
    }

    var for_loops = try scanForLoops(func, allocator);
    defer {
        var flit = for_loops.keyIterator();
        while (flit.next()) |k| allocator.destroy(k);
        for_loops.deinit();
    }

    var visited = std.AutoHashMap(usize, void).init(allocator);
    defer visited.deinit();

    try emitBlock(w, allocator, func, &var_names, resource_names, &visited, &for_loops, 0, null);

    for (func.blocks.items, 0..) |_, idx| {
        if (!visited.contains(idx)) {
            try emitBlock(w, allocator, func, &var_names, resource_names, &visited, &for_loops, idx, null);
        }
    }

    var it = var_names.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
}

fn emitBlock(w: anytype, allocator: Allocator, func: *const gpu_ir.IrFunction, var_names: *std.AutoHashMap(gpu_ir.ValueId, []const u8), resource_names: *const std.StringHashMap(void), visited: *std.AutoHashMap(usize, void), for_loops: *const std.AutoHashMap(usize, ForLoopInfo), block_idx: usize, cond_phi: ?gpu_ir.ValueId) !void {
    if (for_loops.contains(block_idx)) {
        return emitForLoop(w, allocator, func, var_names, resource_names, visited, for_loops, for_loops.get(block_idx).?);
    }
    if (visited.contains(block_idx)) return;
    try visited.put(block_idx, {});

    const block = &func.blocks.items[block_idx];

    for (block.instrs.items) |*inst| {
        var emit_semicolon = true;
        const name_owned = var_names.get(inst.result).?;
        const t = typeRefToHlslType(inst.ty);

        switch (inst.op) {
            .phi => {
                if (cond_phi) |cond| {
                    const cond_name = var_names.get(cond).?;
                    if (inst.operands.len >= 2) {
                        const v0 = var_names.get(inst.operands[0]).?;
                        const v1 = var_names.get(inst.operands[1]).?;
                        try w.print("    {s} = {s} ? {s} : {s};\n", .{ name_owned, cond_name, v0, v1 });
                    }
                }
                emit_semicolon = false;
            },
            .branch => {
                const cond_name = var_names.get(inst.operands[0]).?;
                const cb = inst.data.cond_branch;

                try w.print("    if ({s}) {{\n", .{cond_name});
                try emitBlock(w, allocator, func, var_names, resource_names, visited, for_loops, cb.then_block, null);
                try w.writeAll("    } else {\n");
                try emitBlock(w, allocator, func, var_names, resource_names, visited, for_loops, cb.else_block, null);
                try w.print("    }}\n", .{});

                const then_blk = &func.blocks.items[cb.then_block];
                const else_blk = &func.blocks.items[cb.else_block];

                var then_merge: ?gpu_ir.BlockId = null;
                if (then_blk.instrs.items.len > 0) {
                    const last = then_blk.instrs.getLast();
                    if (last.op == .ret and last.data == .block_target) then_merge = last.data.block_target;
                }
                var else_merge: ?gpu_ir.BlockId = null;
                if (else_blk.instrs.items.len > 0) {
                    const last = else_blk.instrs.getLast();
                    if (last.op == .ret and last.data == .block_target) else_merge = last.data.block_target;
                }

                if (then_merge) |tm| {
                    if (else_merge) |em| {
                        if (tm == em) {
                            try emitBlock(w, allocator, func, var_names, resource_names, visited, for_loops, tm, inst.operands[0]);
                        }
                    }
                }

                emit_semicolon = false;
                return;
            },
            .ret => {
                if (inst.data == .block_target) {
                    emit_semicolon = false;
                    return;
                } else {
                    if (inst.operands.len > 0) {
                        try w.print("    return {s}", .{var_names.get(inst.operands[0]).?});
                    } else {
                        try w.writeAll("    return");
                    }
                }
            },
            .select => {
                try w.print("    {s} = {s} ? {s} : {s}", .{
                    name_owned,
                    var_names.get(inst.operands[0]).?,
                    var_names.get(inst.operands[1]).?,
                    var_names.get(inst.operands[2]).?,
                });
            },
            .cast => {
                const to_type = typeRefToHlslType(inst.ty);
                try w.print("    {s} = ({s}){s}", .{
                    name_owned,
                    to_type,
                    var_names.get(inst.operands[0]).?,
                });
            },
            .@"const" => {
                try w.print("    {s}", .{name_owned});
                switch (inst.ty) {
                    .f32, .vec2f, .vec3f, .vec4f, .f16 => {
                        try w.print(" = {d}", .{inst.data.float_val});
                    },
                    else => {
                        try w.print(" = {d}", .{inst.data.int_val});
                    },
                }
            },
            .load => {
                if (resource_names.contains(inst.data.string) or isArrayLocal(func.locals, inst.data.string)) {
                    try var_names.put(inst.result, try allocator.dupe(u8, inst.data.string));
                    emit_semicolon = false;
                } else {
                    try w.print("    {s} = {s}", .{ name_owned, inst.data.string });
                }
            },
            .store => {
                const base = if (inst.data == .string and inst.data.string.len > 0)
                    inst.data.string
                else
                    var_names.get(inst.operands[0]).?;
                try w.print("    {s}", .{base});
                for (inst.operands[1..inst.operands.len - 1]) |idx_op| {
                    try w.print("[{s}]", .{var_names.get(idx_op).?});
                }
                try w.writeAll(" = ");
                try w.writeAll(var_names.get(inst.operands[inst.operands.len - 1]).?);
            },
            .add => try w.print("    {s} = {s} + {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .sub => try w.print("    {s} = {s} - {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .mul => try w.print("    {s} = {s} * {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .div => try w.print("    {s} = {s} / {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .mod => try w.print("    {s} = {s} % {s}", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .call => {
                if (std.mem.eql(u8, inst.data.call_info.callee, "@array_get")) {
                    try w.print("    {s} = {s}[{s}]", .{
                        name_owned,
                        var_names.get(inst.operands[0]).?,
                        var_names.get(inst.operands[1]).?,
                    });
                } else if (inst.ty == .void) {
                    if (isIntrinsicMethod(inst.data.call_info.callee) and inst.data.call_info.args.len >= 1) {
                        try w.print("    {s}.{s}(", .{
                            var_names.get(inst.data.call_info.args[0]).?,
                            inst.data.call_info.callee,
                        });
                        for (inst.data.call_info.args[1..], 0..) |arg, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(var_names.get(arg).?);
                        }
                    } else {
                        try w.print("    {s}(", .{inst.data.call_info.callee});
                        for (inst.data.call_info.args, 0..) |arg, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(var_names.get(arg).?);
                        }
                    }
                    try w.writeAll(")");
                } else {
                    if (isIntrinsicMethod(inst.data.call_info.callee) and inst.data.call_info.args.len >= 1) {
                        try w.print("    {s} = {s}.{s}(", .{
                            name_owned,
                            var_names.get(inst.data.call_info.args[0]).?,
                            inst.data.call_info.callee,
                        });
                        for (inst.data.call_info.args[1..], 0..) |arg, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(var_names.get(arg).?);
                        }
                    } else {
                        try w.print("    {s} = {s}(", .{ name_owned, inst.data.call_info.callee });
                        for (inst.data.call_info.args, 0..) |arg, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(var_names.get(arg).?);
                        }
                    }
                    try w.writeAll(")");
                }
            },
            .extract => {
                const idx = inst.data.extract_info.index;
                const swz = "xyzw"[idx];
                try w.print("    {s} = {s}.{c}", .{ name_owned, var_names.get(inst.operands[0]).?, swz });
            },
            .composite => {
                try w.print("    {s} = {s}(", .{ name_owned, t });
                for (inst.operands, 0..) |op, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(var_names.get(op).?);
                }
                try w.writeAll(")");
            },
            .max => try w.print("    {s} = max({s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .min => try w.print("    {s} = min({s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .abs => try w.print("    {s} = abs({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .floor => try w.print("    {s} = floor({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .ceil => try w.print("    {s} = ceil({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .frac => try w.print("    {s} = frac({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .sin => try w.print("    {s} = sin({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .cos => try w.print("    {s} = cos({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .exp => try w.print("    {s} = exp({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .sqrt => try w.print("    {s} = sqrt({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .rsqrt => try w.print("    {s} = rsqrt({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .saturate => try w.print("    {s} = saturate({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .dot => try w.print("    {s} = dot({s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .fma => try w.print("    {s} = mad({s}, {s}, {s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).?, var_names.get(inst.operands[2]).? }),
            .lt => try w.print("    {s} = ({s}) < ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .le => try w.print("    {s} = ({s}) <= ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .gt => try w.print("    {s} = ({s}) > ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .ge => try w.print("    {s} = ({s}) >= ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .eq => try w.print("    {s} = ({s}) == ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .ne => try w.print("    {s} = ({s}) != ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .or_op => try w.print("    {s} = ({s}) || ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .and_op => try w.print("    {s} = ({s}) && ({s})", .{ name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
            .not => try w.print("    {s} = !({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .loop => {
                emit_semicolon = false;
            },
            .wave_read_lane_first => try w.print("    {s} = WaveReadLaneFirst({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .wave_get_lane_index => try w.print("    {s} = WaveGetLaneIndex()", .{name_owned}),
            .wave_is_first_lane => try w.print("    {s} = WaveIsFirstLane()", .{name_owned}),
            .wave_active_all_equal => try w.print("    {s} = WaveActiveAllEqual({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .quad_read_across_x => try w.print("    {s} = QuadReadAcrossX({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .quad_read_across_y => try w.print("    {s} = QuadReadAcrossY({s})", .{ name_owned, var_names.get(inst.operands[0]).? }),
            .entry_point, .sample, .atomic, .barrier => {
                try w.print("    {s} = 0 /* unhandled op {s} */", .{ name_owned, @tagName(inst.op) });
            },
        }
        if (emit_semicolon) try w.writeAll(";\n");
    }
}

fn isIntrinsicMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "SampleLevel") or
        std.mem.eql(u8, name, "Sample") or
        std.mem.eql(u8, name, "Load") or
        std.mem.eql(u8, name, "GetDimensions") or
        std.mem.eql(u8, name, "Gather") or
        std.mem.eql(u8, name, "GatherRed") or
        std.mem.eql(u8, name, "GatherGreen") or
        std.mem.eql(u8, name, "GatherBlue") or
        std.mem.eql(u8, name, "GatherAlpha");
}

fn emitIrResourceDecl(w: anytype, res: *const gpu_ir.IrResourceDecl) !void {
    const type_s = switch (res.type_ref) {
        .texture2d => "Texture2D",
        .rw_texture2d => "RWTexture2D",
        .sampler => "SamplerState",
        else => "Texture2D",
    };
    const fmt_s = typeRefToHlslType(res.format);
    if (res.type_ref == .sampler) {
        try w.print("{s} {s};\n", .{ type_s, res.name });
    } else {
        try w.print("{s}<{s}> {s};\n", .{ type_s, fmt_s, res.name });
    }
}

fn typeRefToHlslType(tr: gpu_ir.TypeRef) []const u8 {
    return switch (tr) {
        .f32 => "float",
        .i32 => "int",
        .u32 => "uint",
        .f16 => "half",
        .vec2f => "float2",
        .vec3f => "float3",
        .vec4f => "float4",
        .vec2i => "int2",
        .vec3i => "int3",
        .vec4i => "int4",
        .vec2u => "uint2",
        .vec3u => "uint3",
        .vec4u => "uint4",
        .mat4x4f => "float4x4",
        else => "float",
    };
}

fn emitIrCbuffer(w: anytype, members: []const gpu_ir.IrCbufferMember) !void {
    try w.print("cbuffer TSS_Constants : register(b{}) {{\n", .{ members[0].slot });
    for (members) |mem| {
        try w.print("    {s} {s};\n", .{ typeRefToHlslType(mem.type_ref), mem.name });
    }
    try w.writeAll("};\n");
}

pub const backend: gpu_ir.BackendApi = .{
    .name = "HLSL",
    .target = .hlsl,
    .file_extension = "hlsl",
    .description = "Direct3D HLSL shader text (debug/validation tier)",
    .compile = compileHlslFromIr,
};

/// BackendApi.compile-compatible: compile GPU IR to HLSL text
fn compileHlslFromIr(allocator: Allocator, ir: *const gpu_ir.IrModule, options: gpu_ir.CompileOptions) !gpu_ir.CompileResult {
    _ = options;
    const hlsl = try generateHlslFromIr(allocator, ir);
    return gpu_ir.CompileResult{
        .bytecode = hlsl,
        .allocator = allocator,
    };
}

fn emitResourceDecl(w: anytype, res: *const gpu_ast.ResourceDecl) !void {
    switch (res.gpu_type.kind) {
        .resource_typed => |rt| {
            const fmt = switch (rt.format) { .f32 => "float", .i32 => "int", .u32 => "uint", .f16 => "half", .boolean => "bool" };
            const kind_s = switch (rt.kind) { .texture2d => "Texture2D", .rw_texture2d => "RWTexture2D", else => "Texture2D" };
            const reg_prefix: u8 = if (rt.kind == .rw_texture2d) 'u' else 't';
            const wnum = @intFromEnum(rt.width);
            if (wnum > 1) {
                try w.print("{s}<{s}{c}> {s} : register({c}{});\n", .{ kind_s, fmt, @as(u8, '0' + wnum), res.name, reg_prefix, res.binding.reg });
            } else {
                try w.print("{s}<{s}> {s} : register({c}{});\n", .{ kind_s, fmt, res.name, reg_prefix, res.binding.reg });
            }
        },
        .resource => |rk| {
            const reg_prefix: u8 = switch (rk) { .sampler_state => 's', else => 't' };
            const type_s = switch (rk) {
                .sampler_state => "SamplerState",
                .structured_buffer => "StructuredBuffer<float>",
                .constant_buffer => "ConstantBuffer<float4>",
                else => "Texture2D",
            };
            try w.print("{s} {s} : register({c}{});\n", .{ type_s, res.name, reg_prefix, res.binding.reg });
        },
        else => {},
    }
}

fn emitCbufferDecl(w: anytype, members: []const gpu_ast.CbufferMember) !void {
    try w.print("cbuffer TSS_Constants : register(b{}) {{\n", .{ members[0].slot.reg });
    for (members) |mem| {
        const type_str = switch (mem.scalar_type) {
            .f32 => "float",
            .i32 => "int",
            .u32 => "uint",
            .f16 => "half",
            .boolean => "bool",
        };
        try w.print("    {s} {s};\n", .{ type_str, mem.name });
    }
    try w.writeAll("};\n");
}
