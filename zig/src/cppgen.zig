const std = @import("std");
const ast = @import("ast.zig");

pub const CppOutput = struct {
    text: []u8,
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    program: *const ast.ProgramNode,
    declared_locals: std.StringHashMap(void),
    return_type: ?[]const u8,
};

pub fn generate(allocator: std.mem.Allocator, program: ast.ProgramNode) !CppOutput {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll("#include <cstdint>\n");
    try w.writeAll("#include <cstddef>\n");
    try w.writeAll("#include <cstdio>\n\n");

    // Built-in B+ intrinsics as C++ macros/functions
    try w.writeAll("// B+ builtins\n");
    try w.writeAll("static float saturate(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }\n");
    try w.writeAll("static int32_t saturate_i32(int32_t x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }\n");
    try w.writeAll("static int32_t min_i32(int32_t a, int32_t b) { return a < b ? a : b; }\n");
    try w.writeAll("static int32_t max_i32(int32_t a, int32_t b) { return a > b ? a : b; }\n");
    try w.writeAll("static float min_f(float a, float b) { return a < b ? a : b; }\n");
    try w.writeAll("static float max_f(float a, float b) { return a > b ? a : b; }\n");
    try w.writeAll("static float abs_f(float a) { return a < 0.0f ? -a : a; }\n");
    try w.writeAll("static int32_t abs_i32(int32_t a) { return a < 0 ? -a : a; }\n");
    try w.writeAll("static float min(float a, float b) { return a < b ? a : b; }\n");
    try w.writeAll("static int32_t min(int32_t a, int32_t b) { return a < b ? a : b; }\n");
    try w.writeAll("static float max(float a, float b) { return a > b ? a : b; }\n");
    try w.writeAll("static int32_t max(int32_t a, int32_t b) { return a > b ? a : b; }\n");
    try w.writeAll("static float abs(float a) { return a < 0.0f ? -a : a; }\n");
    try w.writeAll("static int32_t abs(int32_t a) { return a < 0 ? -a : a; }\n\n");

    // Enums
    for (program.enums.items) |e| {
        try w.print("enum class {s} : uint32_t {{\n", .{e.name});
        for (e.members.items, 0..) |m, i| {
            try w.print("    {s}", .{m});
            if (i < e.members.items.len - 1) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("};\n\n");
    }

    // Structs
    {
        var it = program.struct_defs.iterator();
        while (it.next()) |entry| {
            try w.print("struct {s} {{\n", .{entry.key_ptr.*});
            for (entry.value_ptr.fields.items) |f| {
                try w.print("    {s} {s};\n", .{ mapType(f.type_name), f.name });
            }
            try w.writeAll("};\n\n");
        }
    }

    // Forwards (dllimport)
    for (program.forwarders.items) |fwd| {
        try w.print("extern \"C\" __declspec(dllimport) void {s}();\n", .{fwd.export_name});
    }
    if (program.forwarders.items.len > 0) try w.writeAll("\n");

    // ExternCppFn declarations
    for (program.extern_cpp_fns.items) |ext| {
        try w.print("extern \"C\" {s} {s}(", .{ mapType(ext.return_type orelse "void"), ext.name });
        for (ext.parameters.items, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            const raw = p.type_name;
            if (raw.len > 0 and raw[0] == '*') {
                const mapped = mapType(raw[1..]);
                try w.print("{s}* {s}", .{ mapped, p.name });
            } else {
                try w.print("{s} {s}", .{ mapType(raw), p.name });
            }
        }
        try w.writeAll(");\n");
    }
    if (program.extern_cpp_fns.items.len > 0) try w.writeAll("\n");

    // Context (global state variables)
    if (program.context) |ctx| {
        if (ctx.variables.items.len > 0) {
            try w.writeAll("// Context\n");
            for (ctx.variables.items) |v| {
                try w.print("thread_local {s} {s}", .{ mapType(v.type_name), v.name });
                if (v.default_value) |dv| {
                    try w.print(" = {s}", .{dv});
                }
                try w.writeAll(";\n");
            }
            try w.writeAll("\n");
        }
    }

    // State variables as globals (for entries to access)
    for (program.states.items) |*state| {
        for (state.variables.items) |v| {
            try w.print("static {s} {s}_{s} = {{}};\n", .{ mapType(v.type_name), state.name, v.name });
            if (v.default_value) |dv| {
                try w.print(" = {s}", .{dv});
            }
            try w.writeAll("\n");
        }
    }
    if (program.states.items.len > 0 and program.states.items[0].variables.items.len > 0) try w.writeAll("\n");

    // Entries (functions)
    for (program.entries.items) |*entry| {
        try emitEntryFunction(w, entry, &allocator, &program);
    }

    // States → struct with methods
    for (program.states.items) |*state| {
        try emitStateClass(w, state, &allocator, &program);
    }

    return CppOutput{ .text = try buf.toOwnedSlice() };
}

fn emitEntryFunction(w: anytype, entry: *const ast.EntryDecl, allocator: *const std.mem.Allocator, program: *const ast.ProgramNode) !void {
    var decl_locals = std.StringHashMap(void).init(allocator.*);
    defer decl_locals.deinit();
    var ctx = Ctx{
        .allocator = allocator.*,
        .program = program,
        .declared_locals = decl_locals,
        .return_type = entry.return_type,
    };

    const ret_type = mapType(entry.return_type orelse "void");
    try w.print("{s} {s}(", .{ ret_type, entry.name });
    for (entry.params.items, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        const raw_type = p.type_name;
        if (raw_type.len > 0 and raw_type[0] == '*') {
            const mapped = mapType(raw_type[1..]);
            try w.print("{s}* {s}", .{ mapped, p.name });
        } else {
            try w.print("{s} {s}", .{ mapType(raw_type), p.name });
        }
    }
    try w.writeAll(") {\n");
    try transpileBodyLines(w, entry.body_lines.items, &ctx);
    try w.writeAll("}\n\n");
}

fn emitStateClass(w: anytype, state: *const ast.StateDefNode, allocator: *const std.mem.Allocator, program: *const ast.ProgramNode) !void {
    _ = program;
    try w.print("struct {s} {{\n", .{state.name});

    // Variables
    for (state.variables.items) |v| {
        try w.print("    {s} {s}", .{ mapType(v.type_name), v.name });
        if (v.default_value) |dv| {
            try w.print(" = {s}", .{dv});
        }
        try w.writeAll(";\n");
    }

    // Enter body
    if (state.enter_body) |body| {
        try w.writeAll("\n    void enter() {\n");
        try transpileBodyString(w, body, allocator);
        try w.writeAll("    }\n");
    }

    // Exit body
    if (state.exit_body) |body| {
        try w.writeAll("\n    void exit() {\n");
        try transpileBodyString(w, body, allocator);
        try w.writeAll("    }\n");
    }

    try w.writeAll("};\n\n");
}

fn transpileBodyLines(w: anytype, lines_param: []const []const u8, ctx: *Ctx) !void {
    // Pre-merge: combine if ... { body } + next-line else { body } into single line
    const merged = blk: {
        var ml = std.ArrayList([]const u8).init(ctx.allocator);
        var mi: usize = 0;
        while (mi < lines_param.len) : (mi += 1) {
            var cur = lines_param[mi];
            if (std.mem.startsWith(u8, cur, "if ") and std.mem.indexOfScalar(u8, cur, '{') != null) {
                const pos = std.mem.indexOfScalar(u8, cur, '{').?;
                if (findMatchingBraceOnLine(cur, pos) != null and mi + 1 < lines_param.len) {
                    const next = std.mem.trim(u8, lines_param[mi + 1], " \t\r\n");
                    if (std.mem.startsWith(u8, next, "else {")) {
                        cur = try std.mem.concat(ctx.allocator, u8, &.{ cur, " ", next });
                        mi += 1;
                    }
                }
            }
            try ml.append(cur);
        }
        break :blk try ml.toOwnedSlice();
    };
    defer ctx.allocator.free(merged);

    const lines = merged;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const raw = lines[i];
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) continue;

        // Skip annotations/comments that start with B+ @
        if (std.mem.startsWith(u8, line, "@")) continue;

        if (std.mem.startsWith(u8, line, "for(") or std.mem.startsWith(u8, line, "for (")) {
            const body_lines = try extractBlockLines(ctx.allocator, lines, i + 1);
            defer ctx.allocator.free(body_lines);

            const paren_start = std.mem.indexOfScalar(u8, line, '(') orelse { i += body_lines.len; continue; };
            const paren_end_rel = std.mem.indexOfScalar(u8, line[paren_start..], ')') orelse { i += body_lines.len; continue; };
            const parens = std.mem.trim(u8, line[paren_start + 1 .. paren_start + paren_end_rel], " \t");

            if (std.mem.indexOfScalar(u8, parens, ';') != null) {
                var parts = std.mem.splitScalar(u8, parens, ';');
                const init_raw = std.mem.trim(u8, parts.next() orelse "", " \t");
                const cond_raw = std.mem.trim(u8, parts.next() orelse "", " \t");
                const inc_raw = std.mem.trim(u8, parts.next() orelse "", " \t");
                const init_part = if (init_raw.len > 0 and (init_raw[0] >= 'a' and init_raw[0] <= 'z') or init_raw[0] == '_')
                    try std.mem.concat(ctx.allocator, u8, &.{ "int32_t ", init_raw })
                else
                    init_raw;
                try w.print("    for ({s}; {s}; {s}) {{\n", .{ init_part, cond_raw, inc_raw });
                try transpileBodyLines(w, body_lines, ctx);
                try w.writeAll("    }\n");
            } else if (std.mem.indexOfScalar(u8, parens, '=') != null) {
                // for_ch = 0, 4 style — range-based loop
                var pit = std.mem.splitScalar(u8, parens, ',');
                const var_name = std.mem.trim(u8, pit.next() orelse "", " \t");
                const start_val = std.mem.trim(u8, pit.next() orelse "0", " \t");
                const end_val = std.mem.trim(u8, pit.next() orelse "", " \t");
                if (end_val.len > 0) {
                    try w.print("    for (int32_t {s} = {s}; {s} < {s}; {s}++) {{\n", .{ var_name, start_val, var_name, end_val, var_name });
                } else {
                    try w.print("    for (int32_t {s} = {s}; ; {s}++) {{\n", .{ var_name, start_val, var_name });
                }
                try transpileBodyLines(w, body_lines, ctx);
                try w.writeAll("    }\n");
            } else {
                var pit = std.mem.splitScalar(u8, parens, ',');
                const x_var = pit.next() orelse "x";
                const y_var = pit.next() orelse "y";
                const w_val = pit.next() orelse "";
                const has_h = pit.next() orelse "";
                if (has_h.len > 0) {
                    try w.print("    for (uint32_t {s} = 0; {s} < {s}; {s}++) {{\n", .{ y_var, y_var, has_h, y_var });
                }
                const indent = if (has_h.len > 0) "        " else "    ";
                try w.print("{s}for (uint32_t {s} = 0; {s} < {s}; {s}++) {{\n", .{ indent, x_var, x_var, w_val, x_var });
                try transpileBodyLines(w, body_lines, ctx);
                try w.print("{s}}}\n", .{indent});
                if (has_h.len > 0) try w.writeAll("    }\n");
            }
            i += body_lines.len + 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "} else {")) {
            continue;
        }

        if (std.mem.startsWith(u8, line, "while (")) {
            const cond_paren = std.mem.indexOfScalar(u8, line, '(') orelse continue;
            const cond_end = matchingParen(line, cond_paren) orelse continue;
            const condition = std.mem.trim(u8, line[cond_paren + 1 .. cond_end], " \t");
            const body_lines = try extractBlockLines(ctx.allocator, lines, i + 1);
            defer ctx.allocator.free(body_lines);
            try w.print("    while ({s}) {{\n", .{condition});
            try transpileBodyLines(w, body_lines, ctx);
            try w.writeAll("    }\n");
            i += body_lines.len + 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "if ")) {
            const cond_paren = std.mem.indexOfScalar(u8, line, '(') orelse continue;
            const cond_end = matchingParen(line, cond_paren) orelse continue;
            const condition = std.mem.trim(u8, line[cond_paren + 1 .. cond_end], " \t");

            const brace_on_same_line = std.mem.indexOfScalar(u8, line[cond_end + 1 ..], '{');
            const bl = if (brace_on_same_line) |pos| pos + cond_end + 1 else null;

            if (bl) |actual_bl| {
                if (findMatchingBraceOnLine(line, actual_bl)) |body_end| {
                    const if_body = std.mem.trim(u8, line[actual_bl + 1 .. body_end], " \t");
                    try w.print("    if ({s}) {{\n", .{condition});
                    if (if_body.len > 0) {
                        try w.print("        {s};\n", .{transpileStmt(if_body, ctx)});
                    }
                    try w.writeAll("    }");
                    const after_if = std.mem.trim(u8, line[body_end + 1 ..], " \t");
                    if (std.mem.startsWith(u8, after_if, "else")) {
                        const else_brace = std.mem.indexOfScalar(u8, after_if, '{') orelse { try w.writeAll("\n"); continue; };
                        const else_end = findMatchingBraceOnLine(after_if, else_brace) orelse { try w.writeAll("\n"); continue; };
                        const else_body = std.mem.trim(u8, after_if[else_brace + 1 .. else_end], " \t");
                        try w.writeAll(" else {\n");
                        if (else_body.len > 0) {
                            try w.print("        {s};\n", .{transpileStmt(else_body, ctx)});
                        }
                        try w.writeAll("    }\n");
                    } else {
                        try w.writeAll("\n");
                    }
                    continue;
                }
            }

            {
                const body_lines = try extractBlockLines(ctx.allocator, lines, i + 1);
                defer ctx.allocator.free(body_lines);
                try w.print("    if ({s}) {{\n", .{condition});
                try transpileBodyLines(w, body_lines, ctx);
                i += body_lines.len + 1;
                if (i < lines.len) {
                    const next_line = std.mem.trim(u8, lines[i], " \t\r\n");
                    if (std.mem.startsWith(u8, next_line, "else") or std.mem.startsWith(u8, next_line, "} else {")) {
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

        const result = transpileStmt(line, ctx);
        try w.print("    {s};\n", .{result});
    }
}

fn transpileBodyString(w: anytype, body: []const u8, allocator: *const std.mem.Allocator) !void {
    var lines = std.ArrayList([]const u8).init(allocator.*);
    defer lines.deinit();
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        try lines.append(raw);
    }
    var ctx = Ctx{
        .allocator = allocator.*,
        .program = undefined,
        .declared_locals = std.StringHashMap(void).init(allocator.*),
        .return_type = null,
    };
    defer ctx.declared_locals.deinit();
    try transpileBodyLines(w, lines.items, &ctx);
}

fn transpileStmt(stmt: []const u8, ctx: *Ctx) []const u8 {
    const s = std.mem.trimRight(u8, stmt, " \t;\r\n");

    // return expr  →  return expr;
    if (std.mem.startsWith(u8, s, "return ")) {
        const expr = std.mem.trim(u8, s["return ".len..], " \t");
        return tryConcat(&.{ "return ", transpileExpr(expr) });
    }
    if (std.mem.eql(u8, s, "return")) return "return";

    // result = <expr> in a function with return type → return <expr>;
    if (std.mem.startsWith(u8, s, "result ")) {
        if (ctx.return_type != null and !ctx.declared_locals.contains("result")) {
            if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
                return tryConcat(&.{ "return ", transpileExpr(std.mem.trim(u8, s[eq + 1 ..], " \t")) });
            }
        }
    }

    // var name: type = expr  →  type name = expr
    if (std.mem.startsWith(u8, s, "var ")) {
        const decl = std.mem.trim(u8, s["var ".len..], " \t");
        if (std.mem.indexOfScalar(u8, decl, ':')) |colon| {
            const name = std.mem.trim(u8, decl[0..colon], " \t");
            const after_colon = std.mem.trim(u8, decl[colon + 1 ..], " \t");
            ctx.declared_locals.put(name, {}) catch {};

            // Check if type has array suffix: float[12]
            const bracket_pos = std.mem.indexOfScalar(u8, after_colon, '[');
            const base_type_end = bracket_pos orelse after_colon.len;
            const array_suffix = if (bracket_pos) |bp| std.mem.trim(u8, after_colon[bp..], " \t") else "";

            // Find = not inside brackets
            var actual_eq: ?usize = null;
            var depth: i32 = 0;
            var j: usize = 0;
            while (j < after_colon.len) : (j += 1) {
                const c = after_colon[j];
                if (c == '[') { depth += 1; }
                if (c == ']') { depth -= 1; }
                if (c == '=' and depth == 0) { actual_eq = j; break; }
            }

            if (actual_eq) |eq| {
                const typ_str = std.mem.trim(u8, after_colon[0..eq], " \t");
                const val = std.mem.trim(u8, after_colon[eq + 1 ..], " \t");
                const bt_end = std.mem.indexOfScalar(u8, typ_str, '[') orelse typ_str.len;
                const base_for_map = if (typ_str.len > 0 and typ_str[0] == '*') std.mem.trim(u8, typ_str[1..bt_end], " \t") else std.mem.trim(u8, typ_str[0..bt_end], " \t");
                const base_type = mapType(base_for_map);
                const arr_sfx = if (std.mem.indexOfScalar(u8, typ_str, '[')) |bp| typ_str[bp..] else "";
                const pfx = if (typ_str.len > 0 and typ_str[0] == '*') "*" else "";
                if (arr_sfx.len > 0) {
                    return tryConcat(&.{ base_type, pfx, " ", name, arr_sfx, " = ", transpileExpr(val) });
                }
                return tryConcat(&.{ base_type, pfx, " ", name, " = ", transpileExpr(val) });
            } else {
                const base_for_map = if (after_colon.len > 0 and after_colon[0] == '*') std.mem.trim(u8, after_colon[1..base_type_end], " \t") else std.mem.trim(u8, after_colon[0..base_type_end], " \t");
                const base_type = mapType(base_for_map);
                const pfx = if (after_colon.len > 0 and after_colon[0] == '*') "*" else "";
                if (array_suffix.len > 0) {
                    return tryConcat(&.{ base_type, pfx, " ", name, array_suffix });
                }
                return tryConcat(&.{ base_type, pfx, " ", name });
            }
        }
        return s;
    }

    // print("...")  →  printf("...")
    if (std.mem.startsWith(u8, s, "print(")) {
        return tryConcat(&.{ "printf(", s["print(".len..] });
    }

    // *ptr + offset = value  →  ptr[offset] = value
    if (s.len > 0 and s[0] == '*') {
        const eq_pos = std.mem.indexOfScalar(u8, s, '=') orelse return s;
        const lhs = std.mem.trim(u8, s[1..eq_pos], " \t");
        const rhs = std.mem.trim(u8, s[eq_pos + 1 ..], " \t");
        const idx = extractPtrIndex(lhs) orelse return tryConcat(&.{ "*", lhs, " = ", transpileExpr(rhs) });
        return tryConcat(&.{ idx[0], "[", idx[1], "] = ", transpileExpr(rhs) });
    }

    // variable = *ptr + offset  →  variable = ptr[offset]
    if (std.mem.indexOf(u8, s, "= *")) |eq_pos| {
        const lhs = std.mem.trim(u8, s[0..eq_pos], " \t");
        const rhs = std.mem.trim(u8, s[eq_pos + 1 ..], " \t");
        if (rhs.len >= 2 and rhs[0] == '*') {
            const ptr_part = std.mem.trim(u8, rhs[1..], " \t");
            const idx = extractPtrIndex(ptr_part);
            const is_declared = ctx.declared_locals.contains(lhs);
            if (idx) |idxs| {
                if (!is_declared) {
                    ctx.declared_locals.put(lhs, {}) catch {};
                    return tryConcat(&.{ "auto ", lhs, " = ", idxs[0], "[", idxs[1], "]" });
                }
                return tryConcat(&.{ lhs, " = ", idxs[0], "[", idxs[1], "]" });
            }
            if (!is_declared) {
                ctx.declared_locals.put(lhs, {}) catch {};
                return tryConcat(&.{ "auto ", lhs, " = ", ptr_part });
            }
            return tryConcat(&.{ lhs, " = ", ptr_part });
        }
        return s;
    }

    // Track variable definitions: lhs = <expr> without * on either side
    if (std.mem.indexOfScalar(u8, s, '=')) |eq_pos| {
        if (eq_pos > 0 and s[eq_pos - 1] != '*' and s[eq_pos + 1] != '*') {
            const lhs = std.mem.trim(u8, s[0..eq_pos], " \t");
            if (!ctx.declared_locals.contains(lhs) and std.mem.indexOfScalar(u8, lhs, '.') == null and std.mem.indexOfScalar(u8, lhs, '[') == null) {
                ctx.declared_locals.put(lhs, {}) catch {};
                return tryConcat(&.{ "auto ", s });
            }
        }
    }

    // Map B+ intrinsics to C++
    if (std.mem.startsWith(u8, s, "saturate(")) {
        return tryConcat(&.{ "saturate(", s["saturate(".len..] });
    }
    if (std.mem.startsWith(u8, s, "min(")) {
        return tryConcat(&.{ "min_f(", s["min(".len..] });
    }
    if (std.mem.startsWith(u8, s, "max(")) {
        return tryConcat(&.{ "max_f(", s["max(".len..] });
    }
    if (std.mem.startsWith(u8, s, "abs(")) {
        return tryConcat(&.{ "abs_f(", s["abs(".len..] });
    }

    return s;
}

fn transpileExpr(expr: []const u8) []const u8 {
    return expr;
}

fn extractPtrIndex(ptr_expr: []const u8) ?[2][]const u8 {
    // Pattern: base + offset
    const trimmed = std.mem.trim(u8, ptr_expr, " \t");
    if (std.mem.indexOf(u8, trimmed, " + ")) |plus| {
        const base = std.mem.trim(u8, trimmed[0..plus], " \t");
        const idx = std.mem.trim(u8, trimmed[plus + 3 ..], " \t");
        return .{ base, idx };
    }
    // Plain variable with no + offset — not an indexed access
    return null;
}

fn tryConcat(parts: []const []const u8) []const u8 {
    var len: usize = 0;
    for (parts) |p| len += p.len;
    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    for (parts) |p| buf.appendSlice(p) catch {};
    return buf.toOwnedSlice() catch "";
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
        if (std.mem.startsWith(u8, line, "} else {")) {
            break;
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
        if (std.mem.startsWith(u8, trimmed, "} else {")) {
            break;
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

fn findMatchingBraceOnLine(line: []const u8, open_pos: usize) ?usize {
    var depth: u32 = 1;
    var i = open_pos + 1;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '{' => depth += 1,
            '}' => { depth -= 1; if (depth == 0) return i; },
            else => {},
        }
    }
    return null;
}

fn mapType(type_name: []const u8) []const u8 {
    if (std.mem.eql(u8, type_name, "int")) return "int32_t";
    if (std.mem.eql(u8, type_name, "uint")) return "uint32_t";
    if (std.mem.eql(u8, type_name, "float")) return "float";
    if (std.mem.eql(u8, type_name, "float2")) return "float2";
    if (std.mem.eql(u8, type_name, "float3")) return "float3";
    if (std.mem.eql(u8, type_name, "float4")) return "float4";
    if (std.mem.eql(u8, type_name, "double")) return "double";
    if (std.mem.eql(u8, type_name, "bool")) return "bool";
    if (std.mem.eql(u8, type_name, "char")) return "char";
    if (std.mem.eql(u8, type_name, "void")) return "void";
    if (std.mem.eql(u8, type_name, "byte")) return "uint8_t";
    if (std.mem.eql(u8, type_name, "short")) return "int16_t";
    if (std.mem.eql(u8, type_name, "long")) return "int64_t";
    if (std.mem.eql(u8, type_name, "uint64_t")) return "uint64_t";
    return type_name;
}
