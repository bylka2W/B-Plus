const std = @import("std");
const ast = @import("ast.zig");

pub const HlslOutput = struct {
    text: []u8,
};

const VarDef = struct {
    x_expr: []const u8,
    y_expr: []const u8,
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    program: *const ast.ProgramNode,
    bindings: *const std.StringHashMap([]const u8),
    groupshared: std.StringHashMap(u32), // name -> size (elements)
    cbuffers: *const std.StringHashMap([]const u8), // var_name -> "cbName,reg,type"
    x_var: []const u8 = "x",
    y_var: []const u8 = "y",
    var_defs: std.StringHashMap(VarDef),
    declared_locals: std.StringHashMap(void),
};

pub fn generate(allocator: std.mem.Allocator, program: ast.ProgramNode, source: []const u8) !HlslOutput {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    var bindings = try parseBindAnnotations(allocator, source);
    defer {
        var it = bindings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        bindings.deinit();
    }

    var groupshared = try parseGroupsharedAnnotations(allocator, source);
    defer {
        var it = groupshared.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        groupshared.deinit();
    }

    var cbuffers = try parseCbufferAnnotations(allocator, source);
    defer {
        var it = cbuffers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        cbuffers.deinit();
    }

    // Emit cbuffers grouped by cb_name
    try emitCbufferDecls(w, &cbuffers);

    var key_it = bindings.keyIterator();
    while (key_it.next()) |key| {
        try emitResourceDecl(w, key.*, bindings.get(key.*).?);
    }

    // Emit cbuffer for constant-like state variables (dimensions, config)
    try emitConstantBufferDecl(w, &program, &bindings);
    try w.writeAll("\n");

    for (program.entries.items) |*entry| {
        if (!entry.is_export) continue;
        var var_defs = std.StringHashMap(VarDef).init(allocator);
        var decl_locals = std.StringHashMap(void).init(allocator);
        defer {
            var it = var_defs.iterator();
            while (it.next()) |e| allocator.free(e.key_ptr.*);
            var_defs.deinit();
            decl_locals.deinit();
        }
        var ctx = Ctx{
            .allocator = allocator,
            .program = &program,
            .bindings = &bindings,
            .groupshared = groupshared,
            .cbuffers = &cbuffers,
            .var_defs = var_defs,
            .declared_locals = decl_locals,
        };
        try emitEntryShader(w, entry, &ctx);
        try w.writeAll("\n\n");
    }

    return HlslOutput{ .text = try buf.toOwnedSlice() };
}

fn parseBindAnnotations(allocator: std.mem.Allocator, source: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    var pos: usize = 0;
    while (pos < source.len) {
        const bind_start = std.mem.indexOfPos(u8, source, pos, "@bind(") orelse break;
        var end = bind_start + 6;
        var depth: u32 = 1;
        while (end < source.len and depth > 0) : (end += 1) {
            switch (source[end]) {
                '(' => depth += 1,
                ')' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) { pos = bind_start + 6; continue; }
        const ann_text = source[bind_start + 6 .. end - 1];

        var line_start = bind_start;
        while (line_start > 0) : (line_start -= 1) {
            if (source[line_start - 1] == '\n') break;
        }
        const line = source[line_start..bind_start];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |cp| {
            const var_name = std.mem.trim(u8, trimmed[0..cp], " \t");
            if (var_name.len > 0) {
                try map.put(try allocator.dupe(u8, var_name), try allocator.dupe(u8, ann_text));
            }
        }
        pos = end;
    }
    return map;
}

fn parseGroupsharedAnnotations(allocator: std.mem.Allocator, source: []const u8) !std.StringHashMap(u32) {
    var map = std.StringHashMap(u32).init(allocator);
    var pos: usize = 0;
    while (pos < source.len) {
        const gs_start = std.mem.indexOfPos(u8, source, pos, "@groupshared(") orelse break;
        var end = gs_start + 13;
        var depth: u32 = 1;
        while (end < source.len and depth > 0) : (end += 1) {
            switch (source[end]) {
                '(' => depth += 1,
                ')' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) { pos = gs_start + 13; continue; }
        const ann_text = source[gs_start + 13 .. end - 1];

        const comma = std.mem.indexOfScalar(u8, ann_text, ',') orelse { pos = end; continue; };
        const var_name = std.mem.trim(u8, ann_text[0..comma], " \t\"");
        const size_str = std.mem.trim(u8, ann_text[comma + 1 ..], " \t");
        const size = std.fmt.parseInt(u32, size_str, 10) catch { pos = end; continue; };
        if (var_name.len > 0) {
            try map.put(try allocator.dupe(u8, var_name), size);
        }
        pos = end;
    }
    return map;
}

fn parseCbufferAnnotations(allocator: std.mem.Allocator, source: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    var pos: usize = 0;
    while (pos < source.len) {
        const cb_start = std.mem.indexOfPos(u8, source, pos, "@cbuffer(") orelse break;
        var end = cb_start + 9;
        var depth: u32 = 1;
        while (end < source.len and depth > 0) : (end += 1) {
            switch (source[end]) {
                '(' => depth += 1,
                ')' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) { pos = cb_start + 9; continue; }
        const ann_text = source[cb_start + 9 .. end - 1];

        // Format: var_name, cb_name, reg [, type]
        var it = std.mem.splitScalar(u8, ann_text, ',');
        const var_name = std.mem.trim(u8, it.next() orelse "", " \t\"");
        const cb_name = std.mem.trim(u8, it.next() orelse "", " \t\"");
        const reg = std.mem.trim(u8, it.next() orelse "0", " \t");
        const cb_type = std.mem.trim(u8, it.next() orelse "float4", " \t");
        if (var_name.len > 0 and cb_name.len > 0) {
            const val = try std.fmt.allocPrint(allocator, "{s},{s},{s}", .{ cb_name, reg, cb_type });
            try map.put(try allocator.dupe(u8, var_name), val);
        }
        pos = end;
    }
    return map;
}

fn emitCbufferDecls(w: anytype, cbuffers: *const std.StringHashMap([]const u8)) !void {
    // Collect unique cb_names and their fields
    var order = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer order.deinit();
    var cb_to_vars = std.StringHashMap(std.ArrayList([]const u8)).init(std.heap.page_allocator);
    defer {
        var it = cb_to_vars.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        cb_to_vars.deinit();
    }
    var cb_it = cbuffers.iterator();
    while (cb_it.next()) |entry| {
        const val = entry.value_ptr.*;
        var val_it = std.mem.splitScalar(u8, val, ',');
        const cb_name = val_it.next() orelse continue;
        const reg = val_it.next() orelse "0";
        const typ = val_it.next() orelse "float4";
        const field_info = try std.fmt.allocPrint(std.heap.page_allocator, "{s},{s},{s}", .{ entry.key_ptr.*, typ, reg });
        const g = cb_to_vars.getOrPut(cb_name) catch continue;
        if (!g.found_existing) {
            try order.append(cb_name);
            g.value_ptr.* = std.ArrayList([]const u8).init(std.heap.page_allocator);
        }
        try g.value_ptr.*.append(field_info);
    }
    for (order.items) |cb_name| {
        const fields = cb_to_vars.get(cb_name) orelse continue;
        if (fields.items.len == 0) continue;
        // Get register from first field
        var first_it = std.mem.splitScalar(u8, fields.items[0], ',');
        _ = first_it.next(); // var name
        _ = first_it.next(); // type
        const reg = first_it.next() orelse "0";
        try w.print("cbuffer {s} : register(b{s}) {{\n", .{ cb_name, reg });
        for (fields.items) |f| {
            var f_it = std.mem.splitScalar(u8, f, ',');
            const vn = f_it.next() orelse continue;
            const vt = f_it.next() orelse "float4";
            try w.print("    {s} {s};\n", .{ vt, vn });
        }
        try w.writeAll("};\n");
    }
}

fn emitConstantBufferDecl(w: anytype, program: *const ast.ProgramNode, bindings: *const std.StringHashMap([]const u8)) !void {
    var first = true;
    for (program.states.items) |*state| {
        for (state.variables.items) |*v| {
            if (bindings.contains(v.name)) continue;
            if (first) {
                try w.writeAll("cbuffer TSS_Constants : register(b0) {\n");
                first = false;
            }
            const type_hlsl = if (std.mem.eql(u8, v.type_name, "float")) "float" else "int";
            try w.print("    {s} {s};\n", .{ type_hlsl, v.name });
        }
    }
    if (!first) try w.writeAll("};\n");
}

fn emitResourceDecl(w: anytype, name: []const u8, ann: []const u8) !void {
    var it = std.mem.splitScalar(u8, ann, ',');
    const kind = std.mem.trim(u8, it.next() orelse "t", " \t");
    const reg = std.mem.trim(u8, it.next() orelse "0", " \t");
    const fmt = std.mem.trim(u8, it.next() orelse "float", " \t");
    var extra = std.mem.trim(u8, it.next() orelse "", " \t");

    var global_coherent = false;
    if (std.mem.eql(u8, extra, "globallycoherent")) { global_coherent = true; extra = ""; }

    if (std.mem.eql(u8, kind, "t")) {
        try w.print("Texture2D<{s}> {s} : register(t{s});\n", .{ fmt, name, reg });
    } else if (std.mem.eql(u8, kind, "u")) {
        if (global_coherent) {
            try w.print("globallycoherent RWTexture2D<{s}> {s} : register(u{s});\n", .{ fmt, name, reg });
        } else {
            try w.print("RWTexture2D<{s}> {s} : register(u{s});\n", .{ fmt, name, reg });
        }
    } else if (std.mem.eql(u8, kind, "s")) {
        try w.print("SamplerState {s} : register(s{s});\n", .{ name, reg });
    } else if (std.mem.eql(u8, kind, "b")) {
        try w.print("cbuffer {s} : register(b{s}) {{ {s} {s}[{s}]; }};\n", .{ name, reg, fmt, name, extra });
    } else if (std.mem.eql(u8, kind, "t2")) {
        try w.print("Texture2D<{s}> {s} : register(t{s});\n", .{ fmt, name, reg });
    } else if (std.mem.eql(u8, kind, "u2")) {
        try w.print("RWTexture2D<{s}> {s} : register(u{s});\n", .{ fmt, name, reg });
    }
}

fn emitEntryShader(w: anytype, entry: *const ast.EntryDecl, ctx: *Ctx) @TypeOf(w).Error!void {
    var nt_x: u32 = 8;
    var nt_y: u32 = 8;
    const nt_z: u32 = 1;
    var body_start_idx: usize = 0;

    if (entry.body_lines.items.len > 0) {
        const first = entry.body_lines.items[0];
        if (std.mem.indexOf(u8, first, "@numthreads")) |pos| {
            const paren_start = std.mem.indexOfScalar(u8, first[pos..], '(') orelse 0;
            const paren_end = std.mem.indexOfScalar(u8, first[pos + paren_start ..], ')') orelse 0;
            if (paren_start > 0 and paren_end > 0) {
                const args_str = first[pos + paren_start + 1 .. pos + paren_start + paren_end];
                var arg_it = std.mem.splitScalar(u8, args_str, ',');
                if (arg_it.next()) |x_str| nt_x = std.fmt.parseInt(u32, std.mem.trim(u8, x_str, " \t"), 10) catch 8;
                if (arg_it.next()) |y_str| nt_y = std.fmt.parseInt(u32, std.mem.trim(u8, y_str, " \t"), 10) catch 8;
            }
            body_start_idx = 1;
        }
    }

    if (body_start_idx < entry.body_lines.items.len) {
        const first_line = entry.body_lines.items[body_start_idx];
        if (std.mem.startsWith(u8, first_line, "for(")) {
            if (std.mem.indexOfScalar(u8, first_line, '(')) |ps| {
                if (std.mem.indexOfScalar(u8, first_line[ps..], ')')) |pe_rel| {
                    const pe = ps + pe_rel;
                    const args = first_line[ps + 1 .. pe];
                    var it = std.mem.splitScalar(u8, args, ',');
                    if (it.next()) |xv| ctx.x_var = std.mem.trim(u8, xv, " \t");
                    if (it.next()) |yv| ctx.y_var = std.mem.trim(u8, yv, " \t");
                }
            }
        }
    }

    try w.print("[numthreads({d},{d},{d})]\n", .{ nt_x, nt_y, nt_z });
    try w.print("void {s}(uint3 tid : SV_DispatchThreadID, uint3 gid : SV_GroupID, uint3 gtid : SV_GroupThreadID, uint gi : SV_GroupIndex) {{\n", .{ entry.name });

    // Emit groupshared declarations first
    {
        var gs_it = ctx.groupshared.keyIterator();
        while (gs_it.next()) |name| {
            const size = ctx.groupshared.get(name.*).?;
            try w.print("    groupshared float {s}[{d}];\n", .{ name.*, size });
        }
    }

    _ = &ctx.x_var;
    _ = &ctx.y_var;

    try transpileBodyLines(w, entry.body_lines.items[body_start_idx..], ctx);
    try w.writeAll("}\n");
}

fn transpileBodyLines(w: anytype, lines: []const []const u8, ctx: *Ctx) @TypeOf(w).Error!void {
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const raw = lines[i];
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) continue;
        if (std.mem.eql(u8, line, "@unroll")) { try w.writeAll("    [unroll]\n"); continue; }
        if (std.mem.eql(u8, line, "@unroll(loop)")) { try w.writeAll("    [unroll]\n"); continue; }
        if (std.mem.eql(u8, line, "@branch")) { try w.writeAll("    [branch]\n"); continue; }
        if (std.mem.eql(u8, line, "@flatten")) { try w.writeAll("    [flatten]\n"); continue; }
        if (std.mem.eql(u8, line, "@fastopt")) { try w.writeAll("    [fastopt]\n"); continue; }
        if (std.mem.startsWith(u8, line, "@")) continue;

        if (std.mem.startsWith(u8, line, "for (")) {
            const fl_body = try extractBlockLines(ctx.allocator, lines, i + 1);
            defer ctx.allocator.free(fl_body);
            try w.print("    {s}\n", .{line});
            try transpileBodyLines(w, fl_body, ctx);
            try w.writeAll("    }\n");
            i += fl_body.len + 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "for(")) {
            const body_lines = try extractBlockLines(ctx.allocator, lines, i + 1);
            defer ctx.allocator.free(body_lines);

            const paren_start = std.mem.indexOfScalar(u8, line, '(') orelse { i += body_lines.len; continue; };
            const paren_end = std.mem.indexOfScalar(u8, line[paren_start..], ')') orelse { i += body_lines.len; continue; };
            const parens = std.mem.trim(u8, line[paren_start + 1 .. paren_start + paren_end], " \t");
            var pit = std.mem.splitScalar(u8, parens, ',');
            const x_var = std.mem.trim(u8, pit.next() orelse "x", " \t");
            const y_var = std.mem.trim(u8, pit.next() orelse "y", " \t");
            const w_arg = std.mem.trim(u8, pit.next() orelse "", " \t");
            const h_arg = std.mem.trim(u8, pit.next() orelse "", " \t");

            if (w_arg.len > 0 and h_arg.len > 0) {
                try w.print("    uint {s} = tid.x;\n", .{x_var});
                try w.print("    uint {s} = tid.y;\n", .{y_var});
                try w.print("    if ({s} >= {s} || {s} >= {s}) return;\n", .{ x_var, w_arg, y_var, h_arg });
            }

            var sub_ctx = ctx.*;
            sub_ctx.x_var = x_var;
            sub_ctx.y_var = y_var;
            try transpileBodyLines(w, body_lines, &sub_ctx);
            i += body_lines.len + 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "if ")) {
            const cond_paren = std.mem.indexOfScalar(u8, line, '(') orelse continue;
            const cond_end = matchingParen(line, cond_paren) orelse continue;
            const condition = std.mem.trim(u8, line[cond_paren + 1 .. cond_end], " \t");

            const brace_on_same_line = std.mem.indexOfScalar(u8, line[cond_end + 1 ..], '{');
            const bl = if (brace_on_same_line) |pos| pos + cond_end + 1 else null;

            // Try inline if (both braces on same line)
            if (bl) |actual_bl| {
                if (findMatchingBraceOnLine(line, actual_bl)) |body_end| {
                    const if_body = std.mem.trim(u8, line[actual_bl + 1 .. body_end], " \t");
                    try w.print("    if ({s}) {{\n", .{condition});
                    if (if_body.len > 0) try transpileStmt(w, if_body, ctx);
                    try w.writeAll("    }");
                    const after_if = std.mem.trim(u8, line[body_end + 1 ..], " \t");
                    if (std.mem.startsWith(u8, after_if, "else")) {
                        const else_brace = std.mem.indexOfScalar(u8, after_if, '{') orelse { try w.writeAll("\n"); continue; };
                        const else_end = findMatchingBraceOnLine(after_if, else_brace) orelse { try w.writeAll("\n"); continue; };
                        const else_body = std.mem.trim(u8, after_if[else_brace + 1 .. else_end], " \t");
                        try w.writeAll(" else {\n");
                        if (else_body.len > 0) try transpileStmt(w, else_body, ctx);
                        try w.writeAll("    }\n");
                    } else {
                        try w.writeAll("\n");
                    }
                    continue;
                }
                // else: brace on same line but matching brace not on same line → multi-line
            }

            // Multi-line if handler
            {
                const body_lines = try extractBlockLines(ctx.allocator, lines, i + 1);
                defer ctx.allocator.free(body_lines);

                try w.print("    if ({s}) {{\n", .{condition});
                try transpileBodyLines(w, body_lines, ctx);
                i += body_lines.len + 1;

                if (i < lines.len) {
                    const next_line = std.mem.trim(u8, lines[i], " \t\r\n");
                    if (std.mem.startsWith(u8, next_line, "else")) {
                        const else_lines = try extractBlockLines(ctx.allocator, lines, i + 1);
                        defer ctx.allocator.free(else_lines);
                        try w.writeAll("    } else {\n");
                        try transpileBodyLines(w, else_lines, ctx);
                        i += else_lines.len + 2;
                    }
                }
                try w.writeAll("    }\n");
            }
            continue;
        }

        try transpileStmt(w, line, ctx);
    }
}

fn extractBlockLines(allocator: std.mem.Allocator, lines: []const []const u8, start: usize) ![]const []const u8 {
    var depth: u32 = 0;
    var count: usize = 0;
    var i = start;
    while (i < lines.len) : (i += 1) {
        const line = std.mem.trim(u8, lines[i], " \t\r\n");
        if (line.len == 0) {
            if (depth > 0) count += 1;
            continue;
        }
        if (std.mem.eql(u8, line, "{")) {
            depth += 1;
            count += 1;
        } else if (std.mem.eql(u8, line, "}")) {
            if (depth == 0) break;
            depth -= 1;
            if (depth > 0) count += 1;
        } else {
            count += 1;
        }
    }
    const result = try allocator.alloc([]const u8, count);
    var j: usize = 0;
    i = start;
    while (j < count) : (i += 1) {
        const trimmed = std.mem.trim(u8, lines[i], " \t\r\n");
        if (trimmed.len == 0) {
            result[j] = "";
            j += 1;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "{")) {
            result[j] = trimmed;
            j += 1;
        } else if (std.mem.eql(u8, trimmed, "}")) {
            if (j > count) break;
            result[j] = trimmed;
            j += 1;
        } else {
            result[j] = trimmed;
            j += 1;
        }
    }
    return result;
}

fn findMatchingBraceOnLine(line: []const u8, open_pos: usize) ?usize {
    var depth: u32 = 1;
    var i: usize = open_pos + 1;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '{' => depth += 1,
            '}' => { depth -= 1; if (depth == 0) return i; },
            else => {},
        }
    }
    return null;
}

fn transpileBody(w: anytype, body: []const u8, ctx: *Ctx) @TypeOf(w).Error!void {
    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "@numthreads")) continue;
        if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) continue;
        if (std.mem.startsWith(u8, line, "for(")) {
            try transpileFor(w, line, ctx);
        } else if (std.mem.startsWith(u8, line, "if ")) {
            try transpileIf(w, line, ctx);
        } else if (std.mem.startsWith(u8, line, "} else ")) {
        } else if (std.mem.startsWith(u8, line, "else ")) {
        } else {
            try transpileStmt(w, line, ctx);
        }
    }
}

fn transpileStmt(w: anytype, stmt: []const u8, ctx: *Ctx) @TypeOf(w).Error!void {
    const s = std.mem.trimRight(u8, stmt, " \t;\r\n");
    if (std.mem.startsWith(u8, s, "for")) {
        try transpileFor(w, s, ctx);
        return;
    }
    if (std.mem.startsWith(u8, s, "if")) {
        try transpileIf(w, s, ctx);
        return;
    }

    // var name: type  →  type name
    // var name: type = expr  →  type name = expr
    if (std.mem.startsWith(u8, s, "var ")) {
        const decl = std.mem.trim(u8, s["var ".len..], " \t");
        if (std.mem.indexOfScalar(u8, decl, ':')) |colon| {
            const name = std.mem.trim(u8, decl[0..colon], " \t");
            const after_colon = std.mem.trim(u8, decl[colon + 1 ..], " \t");
            try ctx.declared_locals.put(try ctx.allocator.dupe(u8, name), {});
            if (std.mem.indexOfScalar(u8, after_colon, '=')) |eq| {
                const typ = std.mem.trim(u8, after_colon[0..eq], " \t");
                const val = std.mem.trim(u8, after_colon[eq + 1 ..], " \t");
                try w.print("    {s} {s} = {s};\n", .{ typ, name, transpileExpr(val) });
            } else {
                try w.print("    {s} {s};\n", .{ after_colon, name });
            }
        } else {
            try w.print("    {s};\n", .{s});
        }
        return;
    }

    // Passthrough for HLSL intrinsics
    if (std.mem.startsWith(u8, s, "InterlockedAdd") or
        std.mem.startsWith(u8, s, "InterlockedMax") or
        std.mem.startsWith(u8, s, "InterlockedMin") or
        std.mem.startsWith(u8, s, "InterlockedOr") or
        std.mem.startsWith(u8, s, "InterlockedAnd") or
        std.mem.startsWith(u8, s, "InterlockedXor") or
        std.mem.startsWith(u8, s, "InterlockedCompareExchange") or
        std.mem.startsWith(u8, s, "InterlockedExchange") or
        std.mem.startsWith(u8, s, "GroupMemoryBarrierWithGroupSync") or
        std.mem.startsWith(u8, s, "GroupMemoryBarrier") or
        std.mem.startsWith(u8, s, "DeviceMemoryBarrier") or
        std.mem.startsWith(u8, s, "AllMemoryBarrier") or
        std.mem.startsWith(u8, s, "WaveGetLaneIndex") or
        std.mem.startsWith(u8, s, "WaveGetLaneCount") or
        std.mem.startsWith(u8, s, "WaveReadLaneAt") or
        std.mem.startsWith(u8, s, "WaveReadLaneFirst") or
        std.mem.startsWith(u8, s, "WaveActiveSum") or
        std.mem.startsWith(u8, s, "WaveActiveProduct") or
        std.mem.startsWith(u8, s, "WaveActiveMin") or
        std.mem.startsWith(u8, s, "WaveActiveMax") or
        std.mem.startsWith(u8, s, "WaveActiveBitAnd") or
        std.mem.startsWith(u8, s, "WaveActiveBitOr") or
        std.mem.startsWith(u8, s, "WaveActiveBitXor") or
        std.mem.startsWith(u8, s, "WaveActiveAllTrue") or
        std.mem.startsWith(u8, s, "WaveActiveAnyTrue") or
        std.mem.startsWith(u8, s, "WaveActiveBallot") or
        std.mem.startsWith(u8, s, "WaveIsFirstLane") or
        std.mem.startsWith(u8, s, "WavePrefixSum") or
        std.mem.startsWith(u8, s, "WavePrefixProduct") or
        std.mem.startsWith(u8, s, "WavePrefixCountBits") or
        std.mem.startsWith(u8, s, "asuint") or
        std.mem.startsWith(u8, s, "asfloat") or
        std.mem.startsWith(u8, s, "asint") or
        std.mem.startsWith(u8, s, "f32tof16") or
        std.mem.startsWith(u8, s, "f16tof32") or
        std.mem.startsWith(u8, s, "packHalf2x16") or
        std.mem.startsWith(u8, s, "unpackHalf2x16") or
        std.mem.startsWith(u8, s, "packUint2x32") or
        std.mem.startsWith(u8, s, "unpackUint2x32") or
        std.mem.startsWith(u8, s, "floor") or
        std.mem.startsWith(u8, s, "ceil") or
        std.mem.startsWith(u8, s, "frac") or
        std.mem.startsWith(u8, s, "abs") or
        std.mem.startsWith(u8, s, "saturate") or
        std.mem.startsWith(u8, s, "rsqrt") or
        std.mem.startsWith(u8, s, "normalize") or
        std.mem.startsWith(u8, s, "cross") or
        std.mem.startsWith(u8, s, "length") or
        std.mem.startsWith(u8, s, "distance") or
        std.mem.startsWith(u8, s, "round") or
        std.mem.startsWith(u8, s, "sign") or
        std.mem.startsWith(u8, s, "step") or
        std.mem.startsWith(u8, s, "clamp") or
        std.mem.startsWith(u8, s, "lerp") or
        std.mem.startsWith(u8, s, "mad") or
        std.mem.startsWith(u8, s, "sincos") or
        std.mem.startsWith(u8, s, "ddx") or
        std.mem.startsWith(u8, s, "ddy") or
        std.mem.startsWith(u8, s, "ddx_coarse") or
        std.mem.startsWith(u8, s, "ddy_coarse") or
        std.mem.startsWith(u8, s, "ddx_fine") or
        std.mem.startsWith(u8, s, "ddy_fine") or
        std.mem.startsWith(u8, s, "ProcessLane") or
        std.mem.startsWith(u8, s, "ProcessQuad") or
        std.mem.startsWith(u8, s, "NonUniformResourceIndex"))
    {
        try w.print("    {s};\n", .{s});
        return;
    }

    // *var + offset = expr  → UAV write
    if (s.len > 2 and s[0] == '*') {
        const eq_pos = std.mem.indexOfScalar(u8, s, '=') orelse {
            try w.print("{s};\n", .{s});
            return;
        };
        const lhs = std.mem.trim(u8, s[1..eq_pos], " \t");
        const rhs = std.mem.trim(u8, s[eq_pos + 1 ..], " \t");

        const tex_name = findBoundTexture(lhs, ctx.bindings, "u") orelse findBoundTexture(lhs, ctx.bindings, "t");
        if (tex_name) |tn| {
            const coord = extractCoordExpr(lhs, tn, ctx);
            try w.print("    {s}[uint2({s}, {s})] = {s};\n", .{ tn, coord[0], coord[1], transpileExpr(rhs) });
        } else {
            try w.print("    {s} = {s};\n", .{ lhs, transpileExpr(rhs) });
        }
        return;
    }

    // variable = *ptr + offset  (texture read)
    if (std.mem.indexOf(u8, s, "= *")) |eq_pos| {
        const lhs = std.mem.trim(u8, s[0..eq_pos], " \t");
        const rhs = std.mem.trim(u8, s[eq_pos + 1 ..], " \t");
        if (rhs.len >= 2 and rhs[0] == '*') {
            const ptr_part = std.mem.trim(u8, rhs[1..], " \t");
            const tex_name = findBoundTexture(ptr_part, ctx.bindings, "t") orelse findBoundTexture(ptr_part, ctx.bindings, "u");
            if (tex_name) |tn| {
                const coord = extractCoordExpr(ptr_part, tn, ctx);
                const is_local = ctx.declared_locals.contains(lhs);
                const is_state = isStateVar(lhs, ctx.program);
                if (!is_local and !is_state) {
                    const var_type = inferType(lhs, ctx.program);
                    try w.print("    {s} {s} = {s}[uint2({s}, {s})];\n", .{ var_type, lhs, tn, coord[0], coord[1] });
                    try ctx.declared_locals.put(try ctx.allocator.dupe(u8, lhs), {});
                } else {
                    try w.print("    {s} = {s}[uint2({s}, {s})];\n", .{ lhs, tn, coord[0], coord[1] });
                }
                return;
            }
        }
    }

    // Simple assignment (no *) → track var defs
    if (std.mem.indexOfScalar(u8, s, '=')) |eq_pos| {
        if (eq_pos > 0 and s[eq_pos - 1] != '*' and s[eq_pos + 1] != '*') {
            const lhs = std.mem.trim(u8, s[0..eq_pos], " \t");
            const rhs = std.mem.trim(u8, s[eq_pos + 1 ..], " \t");
            tryTrackVarDef(ctx, lhs, rhs);
        }
    }

    try w.print("    {s};\n", .{s});
}

fn tryTrackVarDef(ctx: *Ctx, lhs: []const u8, rhs: []const u8) void {
    // Try to parse rhs as "(rowExpr * width + xExpr) * N" pattern
    const trimmed = std.mem.trim(u8, rhs, " \t");
    if (trimmed.len == 0) return;
    if (trimmed[0] != '(') return;

    const close_paren = matchingParen(trimmed, 0) orelse return;
    const inner = trimmed[1..close_paren];
    const times_pos = std.mem.indexOf(u8, inner, " * ") orelse return;
    const y_expr = std.mem.trim(u8, inner[0..times_pos], " \t");
    const after_times = inner[times_pos + 3 ..];
    const plus_pos = std.mem.indexOf(u8, after_times, " + ") orelse return;
    const x_expr = std.mem.trim(u8, after_times[plus_pos + 3 ..], " \t");

    const key = ctx.allocator.dupe(u8, lhs) catch return;
    ctx.var_defs.put(key, .{ .x_expr = x_expr, .y_expr = y_expr }) catch return;
}

fn transpileFor(w: anytype, stmt: []const u8, ctx: *Ctx) @TypeOf(w).Error!void {
    const paren_start = std.mem.indexOfScalar(u8, stmt, '(') orelse return;
    const paren_end_rel = std.mem.indexOfScalar(u8, stmt[paren_start..], ')') orelse return;
    const paren_end = paren_start + paren_end_rel;
    const parens = std.mem.trim(u8, stmt[paren_start + 1 .. paren_end], " \t");

    // Detect regular for loop (contains ;) vs dispatch loop (comma-separated)
    if (std.mem.indexOfScalar(u8, parens, ';') != null) {
        try w.print("    {s}\n", .{stmt});
        return;
    }

    var it = std.mem.splitScalar(u8, parens, ',');
    const x_var = std.mem.trim(u8, it.next() orelse "x", " \t");
    const y_var = std.mem.trim(u8, it.next() orelse "y", " \t");
    const w_val = std.mem.trim(u8, it.next() orelse "", " \t");
    const h_val = std.mem.trim(u8, it.next() orelse "", " \t");

    const brace_start_rel = std.mem.indexOfScalar(u8, stmt[paren_end..], '{') orelse return;
    const brace_end = lastMatchingBrace(stmt[paren_end + brace_start_rel ..]) orelse return;
    const body_raw = stmt[paren_end + brace_start_rel + 1 .. paren_end + brace_start_rel + brace_end - 1];
    const body_trimmed = std.mem.trim(u8, body_raw, " \t\r\n");

    if (w_val.len > 0 and h_val.len > 0) {
        try w.print("    uint {s} = tid.x;\n", .{x_var});
        try w.print("    uint {s} = tid.y;\n", .{y_var});
        try w.print("    if ({s} >= {s} || {s} >= {s}) return;\n", .{ x_var, w_val, y_var, h_val });
    } else {
        try w.print("    uint {s} = tid.x;\n", .{x_var});
        try w.print("    uint {s} = tid.y;\n", .{y_var});
    }

    var sub_ctx = ctx.*;
    sub_ctx.x_var = x_var;
    sub_ctx.y_var = y_var;
    if (body_trimmed.len > 0) try transpileBody(w, body_trimmed, &sub_ctx);
}

fn transpileIf(w: anytype, stmt: []const u8, ctx: *Ctx) @TypeOf(w).Error!void {
    const if_body_start = std.mem.indexOfScalar(u8, stmt, '{') orelse return;
    const condition = std.mem.trim(u8, stmt["if".len..if_body_start], " \t()");

    const brace_end1 = lastMatchingBrace(stmt[if_body_start..]) orelse return;
    const then_body = std.mem.trim(u8, stmt[if_body_start + 1 .. if_body_start + brace_end1 - 1], " \t\r\n");

    try w.print("    if ({s}) {{\n", .{condition});
    if (then_body.len > 0) try transpileBody(w, then_body, ctx);
    try w.writeAll("    }");

    const rest = std.mem.trim(u8, stmt[if_body_start + brace_end1 ..], " \t\r\n");
    if (std.mem.startsWith(u8, rest, "else")) {
        const else_brace = std.mem.indexOfScalar(u8, rest, '{') orelse {
            try w.writeAll("\n");
            return;
        };
        const else_end = lastMatchingBrace(rest[else_brace..]) orelse {
            try w.writeAll("\n");
            return;
        };
        const else_body = std.mem.trim(u8, rest[else_brace + 1 .. else_brace + else_end - 1], " \t\r\n");
        try w.writeAll(" else {\n");
        if (else_body.len > 0) try transpileBody(w, else_body, ctx);
        try w.writeAll("    }\n");
    } else {
        try w.writeAll("\n");
    }
}

fn transpileExpr(expr: []const u8) []const u8 {
    return expr;
}

fn isStateVar(name: []const u8, program: *const ast.ProgramNode) bool {
    for (program.states.items) |*state| {
        for (state.variables.items) |*v| {
            if (std.mem.eql(u8, v.name, name)) return true;
        }
    }
    return false;
}

fn mapTypeToHlsl(type_name: []const u8) []const u8 {
    // FSR2 abstract types
    if (std.mem.eql(u8, type_name, "float")) return "float";
    if (std.mem.eql(u8, type_name, "float2")) return "float2";
    if (std.mem.eql(u8, type_name, "float3")) return "float3";
    if (std.mem.eql(u8, type_name, "float4")) return "float4";
    if (std.mem.eql(u8, type_name, "int")) return "int";
    if (std.mem.eql(u8, type_name, "int2")) return "int2";
    if (std.mem.eql(u8, type_name, "int3")) return "int3";
    if (std.mem.eql(u8, type_name, "int4")) return "int4";
    if (std.mem.eql(u8, type_name, "uint")) return "uint";
    if (std.mem.eql(u8, type_name, "uint2")) return "uint2";
    if (std.mem.eql(u8, type_name, "uint3")) return "uint3";
    if (std.mem.eql(u8, type_name, "uint4")) return "uint4";
    // FSR2 abstract type aliases
    if (std.mem.eql(u8, type_name, "FfxFloat32")) return "float";
    if (std.mem.eql(u8, type_name, "FfxFloat32x2")) return "float2";
    if (std.mem.eql(u8, type_name, "FfxFloat32x3")) return "float3";
    if (std.mem.eql(u8, type_name, "FfxFloat32x4")) return "float4";
    if (std.mem.eql(u8, type_name, "FfxInt32")) return "int";
    if (std.mem.eql(u8, type_name, "FfxInt32x2")) return "int2";
    if (std.mem.eql(u8, type_name, "FfxInt32x3")) return "int3";
    if (std.mem.eql(u8, type_name, "FfxInt32x4")) return "int4";
    if (std.mem.eql(u8, type_name, "FfxUInt32")) return "uint";
    if (std.mem.eql(u8, type_name, "FfxUInt32x2")) return "uint2";
    if (std.mem.eql(u8, type_name, "FfxUInt32x3")) return "uint3";
    if (std.mem.eql(u8, type_name, "FfxUInt32x4")) return "uint4";
    if (std.mem.eql(u8, type_name, "FfxBoolean")) return "bool";
    if (std.mem.eql(u8, type_name, "FfxInt32")) return "int";
    return "float";
}

fn inferType(name: []const u8, program: *const ast.ProgramNode) []const u8 {
    for (program.states.items) |*state| {
        for (state.variables.items) |*v| {
            if (std.mem.eql(u8, v.name, name)) {
                if (std.mem.eql(u8, v.type_name, "float")) return "float";
                return "uint";
            }
        }
    }
    const float_hints = [_]u8{ 'v', 'f', 'p', 'c', 'n', 's', 'e', 'w', 'h', 'l', 'm' };
    if (name.len > 0 and std.mem.indexOfScalar(u8, &float_hints, name[0]) != null) return "float";
    return "uint";
}

fn findBoundTexture(ptr_expr: []const u8, bindings: *const std.StringHashMap([]const u8), kind: []const u8) ?[]const u8 {
    const first_word_end = std.mem.indexOfAny(u8, ptr_expr, " +-*/") orelse ptr_expr.len;
    const base_name = ptr_expr[0..first_word_end];

    if (bindings.get(base_name)) |ann| {
        const trimmed = std.mem.trim(u8, ann, " \t");
        var it = std.mem.splitScalar(u8, trimmed, ',');
        const k = std.mem.trim(u8, it.next() orelse "", " \t");
        if (std.mem.eql(u8, k, kind)) return base_name;
    }
    return null;
}

fn matchingParen(s: []const u8, open_pos: usize) ?usize {
    var depth: u32 = 1;
    var i = open_pos + 1;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(' => depth += 1,
            ')' => { depth -= 1; if (depth == 0) return i; },
            else => {},
        }
    }
    return null;
}

fn extractCoordExpr(ptr_expr: []const u8, tex_name: []const u8, ctx: *Ctx) [2][]const u8 {
    const after_base = std.mem.trimLeft(u8, ptr_expr[tex_name.len..], " +");

    // Pattern: "(rowExpr * width + xExpr) * N"
    if (after_base.len > 0 and after_base[0] == '(') {
        const close_paren = matchingParen(after_base, 0) orelse return .{ ctx.x_var, ctx.y_var };
        const inner = after_base[1..close_paren];
        const times_pos = std.mem.indexOf(u8, inner, " * ") orelse return .{ ctx.x_var, ctx.y_var };
        const row_var = std.mem.trim(u8, inner[0..times_pos], " \t");
        const after_times = inner[times_pos + 3 ..];
        const plus_pos = std.mem.indexOf(u8, after_times, " + ") orelse return .{ ctx.x_var, ctx.y_var };
        const x_var = std.mem.trim(u8, after_times[plus_pos + 3 ..], " \t");
        return .{ x_var, row_var };
    }

    // Pattern: varName, varName - N, varName + N (from var_defs)
    const word_end = std.mem.indexOfAny(u8, after_base, " +-") orelse after_base.len;
    const var_name = after_base[0..word_end];
    if (ctx.var_defs.get(var_name)) |def| {
        const rest = std.mem.trim(u8, after_base[word_end..], " \t");
        if (rest.len == 0) return .{ def.x_expr, def.y_expr };

        // Check for hoff ± 4 (x-offset) vs hoff ± ow*4 (y-offset)
        const is_minus = std.mem.startsWith(u8, rest, "- ");
        const is_plus = std.mem.startsWith(u8, rest, "+ ");
        if (is_minus or is_plus) {
            const offset_val = std.mem.trim(u8, rest[2..], " \t");
            const has_mul = std.mem.indexOfScalar(u8, offset_val, '*') != null;
            if (has_mul) {
                // y ± 1
                const op = if (is_minus) "-" else "+";
                // Return { x, y op 1 } — but we can't allocate. Use a hack:
                // The function returns slices that must outlive the call.
                // Since ctx.x_var/y_var are stable, and the caller uses them
                // immediately in w.print(), we just leak the allocated result.
                const y_new = std.fmt.allocPrint(ctx.allocator, "{s} {s} 1", .{ def.y_expr, op }) catch return .{ def.x_expr, def.y_expr };
                return .{ def.x_expr, y_new };
            } else {
                // x ± 1
                const op = if (is_minus) "-" else "+";
                const x_new = std.fmt.allocPrint(ctx.allocator, "{s} {s} 1", .{ def.x_expr, op }) catch return .{ def.x_expr, def.y_expr };
                return .{ x_new, def.y_expr };
            }
        }
        return .{ def.x_expr, def.y_expr };
    }

    return .{ ctx.x_var, ctx.y_var };
}

fn lastMatchingBrace(s: []const u8) ?usize {
    var depth: u32 = 0;
    for (s, 0..) |c, i| {
        switch (c) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}
