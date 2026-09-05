const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const scope_mod = @import("scope.zig");

fn inferTypeFromValue(allocator: Allocator, default_value: []const u8) ![]const u8 {
    if (default_value.len > 0) {
        var is_number = true;
        var has_dot = false;
        for (default_value, 0..) |ch, i| {
            if (i == 0 and (ch == '-' or ch == '+')) continue;
            if (ch == '.') {
                if (has_dot) { is_number = false; break; }
                has_dot = true;
                continue;
            }
            if (ch < '0' or ch > '9') { is_number = false; break; }
        }
        
        if (is_number and default_value.len > 0) {
            if (has_dot) {

                return try allocator.dupe(u8, "f64");
            } else {
                return try allocator.dupe(u8, "i64");
            }
        }
        
        // String literal → string
        if (default_value[0] == '"' and default_value[default_value.len - 1] == '"') {
            return try allocator.dupe(u8, "string");
        }
        
        // Boolean literals
        if (std.mem.eql(u8, default_value, "true") or std.mem.eql(u8, default_value, "false")) {
            return try allocator.dupe(u8, "bool");
        }
    }
    
    // Default to i64 if can't infer (B+ default integer)
    return try allocator.dupe(u8, "i64");
}

/// Infer function return type from its body's return statements.
/// Scans body lines for `return expr` and infers type from the expression.
/// Falls back to "i64" (B+ default) if no return found or can't infer.
fn inferReturnTypeName(func: ast.EntryDecl) []const u8 {
    for (func.body_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "return")) continue;
        const rest = std.mem.trim(u8, trimmed["return".len..], " \t\r\n");
        if (rest.len == 0) continue; // bare `return` → void, keep scanning
        // Try simple literal inference
        if (rest[0] == '"') return "string";
        if (std.mem.eql(u8, rest, "true") or std.mem.eql(u8, rest, "false")) return "bool";
        // Numeric literal
        var is_num = true;
        var has_dot = false;
        for (rest, 0..) |ch, i| {
            if (i == 0 and (ch == '-' or ch == '+')) continue;
            if (ch == '.') { if (has_dot) { is_num = false; break; } has_dot = true; continue; }
            if (ch < '0' or ch > '9') { is_num = false; break; }
        }
        if (is_num and rest.len > 0) {
            return if (has_dot) "f64" else "i64";
        }
        // For variables/expressions, default to i64
        return "i64";
    }
    return "void";
}

pub const SemaError = error{
    UndefinedVariable,
    UndefinedFunction,
    UndefinedState,
    UndefinedStruct,
    InvalidEnumValue,
    InvalidStructField,
    ArityMismatch,
    ArgTypeMismatch,
    TypeError,
    BinaryTypeMismatch,
    ImportError,
    ImportNotFound,
    DuplicateDefinition,
    BreakOutsideLoop,
    ContinueOutsideLoop,
    ReturnTypeMismatch,
    NegativeArrayIndex,
    OutOfMemory,
};

pub const TypedVarInfo = struct {
    name: []const u8,
    type_id: ast.TypeId,
    type_name: ?[]const u8,
    scope_level: u32,
};

pub const SemaResult = struct {
    allocator: Allocator,
    typed_vars: std.ArrayList(TypedVarInfo),
    defined_func_names: std.ArrayList([]const u8),
    defined_struct_names: std.ArrayList([]const u8),
    defined_enum_names: std.ArrayList([]const u8),

    pub fn deinit(self: *const SemaResult) void {
        for (self.typed_vars.items) |v| {
            self.allocator.free(v.name);
            if (v.type_name) |tn| self.allocator.free(tn);
        }
        self.typed_vars.deinit();
        for (self.defined_func_names.items) |n| self.allocator.free(n);
        self.defined_func_names.deinit();
        for (self.defined_struct_names.items) |n| self.allocator.free(n);
        self.defined_struct_names.deinit();
        for (self.defined_enum_names.items) |n| self.allocator.free(n);
        self.defined_enum_names.deinit();
    }

    pub fn lookupVarType(self: *const SemaResult, name: []const u8) ?ast.TypeId {
        var i: usize = self.typed_vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.typed_vars.items[i].name, name)) {
                return self.typed_vars.items[i].type_id;
            }
        }
        return null;
    }

    pub fn isFunction(self: *const SemaResult, name: []const u8) bool {
        for (self.defined_func_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    pub fn isStruct(self: *const SemaResult, name: []const u8) bool {
        for (self.defined_struct_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    pub fn isEnum(self: *const SemaResult, name: []const u8) bool {
        for (self.defined_enum_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};

pub fn analyze(allocator: Allocator, program: ast.ProgramNode, src: []const u8, file_path: []const u8) !SemaResult {

    // ── Rich AST data stores (kept for detailed type info) ──
    var defined_funcs = std.StringHashMap(ast.EntryDecl).init(allocator);
    defer defined_funcs.deinit();

    var defined_structs = std.StringHashMap(ast.StructDef).init(allocator);
    defer defined_structs.deinit();

    var defined_enums = std.StringHashMap(ast.EnumDecl).init(allocator);
    defer defined_enums.deinit();

    // ── Symbol Table: replaces local_vars, local_var_types, defined_states ──
    var symtab = try scope_mod.ScopeTable.init(allocator);
    defer symtab.deinit();

    // Register global symbols in root scope
    for (program.plan.states.items) |state| {
        if (symtab.isDefinedInCurrentScope(state.name)) {
            const ln = findLineNumber(src, state.name);
            std.log.err("{s}:{d}: error: duplicate state definition '{s}'", .{ file_path, ln, state.name });
            return SemaError.DuplicateDefinition;
        }
        try symtab.define(state.name, .state, .void, null);
    }

    for (program.common.func_defs.items) |func| {
        if (symtab.isDefinedInCurrentScope(func.name)) {
            const ln = findLineNumber(src, func.name);
            std.log.err("{s}:{d}: error: duplicate function definition '{s}'", .{ file_path, ln, func.name });
            return SemaError.DuplicateDefinition;
        }
        const rt = func.return_type orelse inferReturnTypeName(func);
        try symtab.define(func.name, .function, ast.TypeId.fromName(rt), func.return_type);
        try defined_funcs.put(func.name, func);
    }

    {
        var struct_it = program.common.struct_defs.iterator();
        while (struct_it.next()) |entry| {
            try symtab.define(entry.key_ptr.*, .struct_def, .struct_type, entry.key_ptr.*);
            try defined_structs.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    for (program.common.enums.items) |en| {
        if (symtab.isDefinedInCurrentScope(en.name)) {
            const ln = findLineNumber(src, en.name);
            std.log.err("{s}:{d}: error: duplicate enum definition '{s}'", .{ file_path, ln, en.name });
            return SemaError.DuplicateDefinition;
        }
        try symtab.define(en.name, .enum_def, .enum_type, en.name);
        try defined_enums.put(en.name, en);
    }

    // ── Pass 2: Validate imports ──
    for (program.common.imports.items) |imp| {
        const file = std.fs.cwd().openFile(imp.path, .{}) catch {
            const ln = findLineNumber(src, imp.path);
            std.log.err("{s}:{d}: error: import file not found '{s}'", .{ file_path, ln, imp.path });
            return SemaError.ImportNotFound;
        };
        file.close();
    }

    // ── Pass 3: Validate transitions & state bodies ──
    for (program.plan.states.items) |state| {
        for (state.transitions.items) |trans| {
            if (symtab.lookup(trans.target) == null) {
                const ln = findLineNumber(src, state.name);
                std.log.err("{s}:{d}: error: undefined state '{s}' in transition from state '{s}'", .{ file_path, ln, trans.target, state.name });
                return SemaError.UndefinedState;
            }
        }
        if (state.enter_body) |body| {
            try validateBody(allocator, body, state.name, state.variables.items, &symtab, &defined_funcs, &defined_structs, &defined_enums, file_path, src);
        }
    }

    // ── Pass 4: Validate function bodies & return counts ──
    for (program.common.func_defs.items) |func| {
        try validateFuncBody(allocator, func, &symtab, &defined_funcs, &defined_structs, &defined_enums, file_path, src);
    }

    // ── Build SemaResult with collected typed context ──
    var result = SemaResult{
        .allocator = allocator,
        .typed_vars = std.ArrayList(TypedVarInfo).init(allocator),
        .defined_func_names = std.ArrayList([]const u8).init(allocator),
        .defined_struct_names = std.ArrayList([]const u8).init(allocator),
        .defined_enum_names = std.ArrayList([]const u8).init(allocator),
    };
    errdefer result.deinit();

    for (program.common.func_defs.items) |func| {
        try result.defined_func_names.append(try allocator.dupe(u8, func.name));
    }
    {
        var struct_it = program.common.struct_defs.iterator();
        while (struct_it.next()) |entry| {
            try result.defined_struct_names.append(try allocator.dupe(u8, entry.key_ptr.*));
        }
    }
    for (program.common.enums.items) |en| {
        try result.defined_enum_names.append(try allocator.dupe(u8, en.name));
    }

    // Collect typed variables from symtab by walking all scopes
    try collectTypedVars(&symtab, &result);

    return result;
}

fn collectTypedVars(symtab: *scope_mod.ScopeTable, result: *SemaResult) !void {
    var scope: ?*scope_mod.Scope = symtab.current;
    while (scope) |s| {
        var it = s.symbols.iterator();
        while (it.next()) |entry| {
            const sym = entry.value_ptr.*;
            try result.typed_vars.append(.{
                .name = try result.allocator.dupe(u8, sym.name),
                .type_id = sym.type_id,
                .type_name = if (sym.type_name) |tn| try result.allocator.dupe(u8, tn) else null,
                .scope_level = sym.scope_level,
            });
        }
        scope = s.parent;
    }
}

fn validateFuncBody(
    allocator: Allocator,
    func: ast.EntryDecl,
    parent_symtab: *scope_mod.ScopeTable,
    defined_funcs: *const std.StringHashMap(ast.EntryDecl),
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    // Push a new scope for this function
    try parent_symtab.pushScope();
    defer parent_symtab.popScope();

    // Register parameters in the function scope
    for (func.params.items) |param| {
        const type_id = ast.TypeId.fromName(param.type_name);
        try parent_symtab.define(param.name, .param, type_id, param.type_name);
        try validateTypeRef(param.type_name, defined_structs, defined_enums, file_path, src);
    }

    var return_count: usize = 0;
    for (func.body_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "return")) return_count += 1;

        //for init; cond; update { body } — парсим init чтобы создать переменную
        if (std.mem.startsWith(u8, trimmed, "for ") or std.mem.startsWith(u8, trimmed, "for(")) {
            const rest = if (trimmed[3] == ' ') trimmed[4..] else trimmed[4..];
            const header = if (std.mem.indexOfScalar(u8, rest, '{')) |brace| rest[0..brace] else rest;
            const header_trim = std.mem.trim(u8, header, " \t\r\n");
            var depth: i32 = 0;
            var si: usize = header_trim.len;
            for (header_trim, 0..) |ch, idx| {
                if (ch == '(') depth += 1;
                if (ch == ')') depth -= 1;
                if (ch == ';' and depth == 0) {
                    si = idx;
                    break;
                }
            }
            const init_part = std.mem.trim(u8, header_trim[0..si], " \t\r\n");
            if (init_part.len > 0) {
                if (std.mem.indexOfScalar(u8, init_part, '=')) |eq| {
                    const var_name = std.mem.trim(u8, init_part[0..eq], " \t\r\n");
                    if (var_name.len > 0) {
                        const rhs = std.mem.trim(u8, init_part[eq + 1 ..], " \t\r\n");
                        const inferred_type = try inferTypeFromValue(allocator, rhs);
                        defer allocator.free(inferred_type);
                        const type_id = ast.TypeId.fromName(inferred_type);
                        try parent_symtab.define(var_name, .variable, type_id, inferred_type);
                    }
                }
            }
        }

        // var x:i32 = 10 (old syntax)
        if (std.mem.startsWith(u8, trimmed, "var ")) {
            const rest = trimmed["var ".len..];
            const name = extractVarName(rest);
            const vtype = extractVarType(rest);
            if (name.len > 0) {
                const type_id = if (vtype) |vt| ast.TypeId.fromName(vt) else .unknown;
                try parent_symtab.define(name, .variable, type_id, vtype);
                if (vtype) |vt| {
                    try validateTypeRef(vt, defined_structs, defined_enums, file_path, src);
                }
            }
        }
        // x = 10 or x:i64 = 10 (new auto-infer syntax)
        else if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
            const lhs = std.mem.trim(u8, trimmed[0..eq_idx], " \t\r\n");
            // Check for type annotation: x:i64 = 10
            if (std.mem.indexOfScalar(u8, lhs, ':')) |colon_idx| {
                const var_name = std.mem.trim(u8, lhs[0..colon_idx], " \t\r\n");
                const type_name = std.mem.trim(u8, lhs[colon_idx + 1 ..], " \t\r\n");
                if (var_name.len > 0 and type_name.len > 0) {
                    const type_id = ast.TypeId.fromName(type_name);
                    try parent_symtab.define(var_name, .variable, type_id, type_name);
                    try validateTypeRef(type_name, defined_structs, defined_enums, file_path, src);
                }
            }
            // x = 10 (auto-infer)
            else if (lhs.len > 0) {
                // Infer type from RHS
                const rhs = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\r\n");
                const inferred_type = try inferTypeFromValue(allocator, rhs);
                defer allocator.free(inferred_type);
                const type_id = ast.TypeId.fromName(inferred_type);
                try parent_symtab.define(lhs, .variable, type_id, inferred_type);
            }
        }

        try validateBodyLine(allocator, trimmed, parent_symtab, defined_funcs, defined_structs, defined_enums, file_path, src);
    }

    const has_return_type = func.return_type != null;
    if (has_return_type and return_count == 0) {
        if (func.return_type) |rt| {
            if (!std.mem.eql(u8, rt, "void")) {
                const ln = findLineNumber(src, func.name);
                std.log.err("{s}:{d}: error: function '{s}' declares return type '{s}' but has no return statement", .{ file_path, ln, func.name, rt });
                return SemaError.ReturnTypeMismatch;
            }
        }
    }
    // B+ design: return type is optional. If function has return statements
    // but no explicit return type, the type is inferred from return expressions.
    // No error needed here — the BIR frontend handles inference.
}

fn validateBody(
    allocator: Allocator,
    body: []const u8,
    state_name: []const u8,
    state_vars: []const ast.VariableNode,
    parent_symtab: *scope_mod.ScopeTable,
    defined_funcs: *const std.StringHashMap(ast.EntryDecl),
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    // Push a new scope for the state entry body
    try parent_symtab.pushScope();
    defer parent_symtab.popScope();

    // Register state variables
    for (state_vars) |v| {
        // Auto-infer type if not specified
        const resolved_type_name = if (v.type_name) |tn| tn 
            else if (v.default_value) |dv| try inferTypeFromValue(allocator, dv)
            else "i32";
        const type_id = ast.TypeId.fromName(resolved_type_name);
        try parent_symtab.define(v.name, .variable, type_id, resolved_type_name);
        if (v.type_name) |tn| {
            try validateTypeRef(tn, defined_structs, defined_enums, file_path, src);
        }
    }

    var brace_depth: i32 = 0;
    var loop_levels = std.ArrayList(i32).init(allocator);
    defer loop_levels.deinit();

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        var stmts = std.mem.splitScalar(u8, line, ';');
        while (stmts.next()) |stmt| {
            const trimmed = std.mem.trim(u8, stmt, " \t\r\n");
            if (trimmed.len == 0) continue;

            const is_break = std.mem.eql(u8, trimmed, "break");
            const is_continue = std.mem.eql(u8, trimmed, "continue");
            if (is_break or is_continue) {
                if (loop_levels.items.len == 0) {
                    const ln = findLineNumber(src, trimmed);
                    if (is_break) {
                        std.log.err("{s}:{d}: error: 'break' outside loop in state '{s}'", .{ file_path, ln, state_name });
                        return SemaError.BreakOutsideLoop;
                    } else {
                        std.log.err("{s}:{d}: error: 'continue' outside loop in state '{s}'", .{ file_path, ln, state_name });
                        return SemaError.ContinueOutsideLoop;
                    }
                }
            }

            if (std.mem.startsWith(u8, trimmed, "var ")) {
                const rest = trimmed["var ".len..];
                const name = extractVarName(rest);
                const vtype = extractVarType(rest);
                if (name.len > 0) {
                    const type_id = if (vtype) |vt| ast.TypeId.fromName(vt) else .unknown;
                    try parent_symtab.define(name, .variable, type_id, vtype);
                    if (vtype) |vt| {
                        try validateTypeRef(vt, defined_structs, defined_enums, file_path, src);
                    }
                }
            }

            const has_while = std.mem.indexOf(u8, trimmed, "while") != null;
            const has_for = std.mem.indexOf(u8, trimmed, "for") != null;
            var loop_pending = has_while or has_for;

            for (trimmed) |c| {
                if (c == '{') {
                    brace_depth += 1;
                    if (loop_pending) {
                        try loop_levels.append(brace_depth);
                        loop_pending = false;
                    }
                } else if (c == '}') {
                    var j: usize = loop_levels.items.len;
                    while (j > 0) {
                        j -= 1;
                        if (loop_levels.items[j] == brace_depth) {
                            _ = loop_levels.orderedRemove(j);
                        }
                    }
                    brace_depth -= 1;
                }
            }

            if (isControlKeyword(trimmed)) continue;

            try validateBodyLine(allocator, trimmed, parent_symtab, defined_funcs, defined_structs, defined_enums, file_path, src);
        }
    }
}

fn validateBodyLine(
    allocator: Allocator,
    line: []const u8,
    symtab: *scope_mod.ScopeTable,
    defined_funcs: *const std.StringHashMap(ast.EntryDecl),
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    if (line.len == 0) return;

    if (std.mem.indexOf(u8, line, "[-") != null) {
        const ln = findLineNumber(src, line);
        std.log.err("{s}:{d}: error: negative array index is not supported", .{ file_path, ln });
        return SemaError.NegativeArrayIndex;
    }

    if (isControlKeyword(line)) return;

    if (findFunctionCall(line)) |call_info| {
        if (!isBuiltin(call_info.name)) {
            if (symtab.lookup(call_info.name) == null) {
                const ln = findLineNumber(src, line);
                std.log.err("{s}:{d}: error: undefined function '{s}'", .{ file_path, ln, call_info.name });
                return SemaError.UndefinedFunction;
            } else if (defined_funcs.get(call_info.name)) |func_def| {
                const actual = countArgs(call_info.args);
                const expected = func_def.params.items.len;
                if (actual != expected) {
                    const ln = findLineNumber(src, line);
                    std.log.err("{s}:{d}: error: function '{s}' expects {d} arguments but got {d}", .{ file_path, ln, call_info.name, expected, actual });
                    return SemaError.ArityMismatch;
                }
                try checkFuncArgTypes(allocator, call_info, &func_def, symtab, defined_structs, defined_enums, defined_funcs, file_path, src);
            }
        }
    }

    try validateVarRefs(line, symtab, defined_structs, defined_enums, file_path, src);

    // Phase 1: Type checking
    try checkTypeAssignment(line, symtab, defined_structs, defined_enums, defined_funcs, file_path, src);
    try checkBinaryTypeMismatch(line, symtab, defined_structs, defined_enums, defined_funcs, file_path, src);
}

fn validateVarRefs(
    line: []const u8,
    symtab: *scope_mod.ScopeTable,
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r' or line[i] == '\n')) : (i += 1) {}
        if (i >= line.len) break;

        if (line[i] == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            if (i < line.len) i += 1;
            continue;
        }

        if (std.ascii.isDigit(line[i]) or (line[i] == '-' and i + 1 < line.len and std.ascii.isDigit(line[i + 1]))) {
            if (line[i] == '-') i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '.' or line[i] == 'x' or (line[i] >= 'a' and line[i] <= 'f') or (line[i] >= 'A' and line[i] <= 'F'))) : (i += 1) {}
            continue;
        }

        if (std.ascii.isAlphabetic(line[i]) or line[i] == '_') {
            const start = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) : (i += 1) {}
            const ident = line[start..i];

            const after_ident = std.mem.trimLeft(u8, line[i..], " \t");

            if (after_ident.len > 0 and after_ident[0] == '(') continue;

            // Dot access: EnumName.Value or var.field
            if (after_ident.len > 0 and after_ident[0] == '.') {
                var dot_j: usize = 1;
                while (dot_j < after_ident.len and (after_ident[dot_j] == ' ' or after_ident[dot_j] == '\t')) : (dot_j += 1) {}
                var field_name: []const u8 = "";
                if (dot_j < after_ident.len and (std.ascii.isAlphabetic(after_ident[dot_j]) or after_ident[dot_j] == '_')) {
                    const val_start = dot_j;
                    dot_j += 1;
                    while (dot_j < after_ident.len and (std.ascii.isAlphanumeric(after_ident[dot_j]) or after_ident[dot_j] == '_')) : (dot_j += 1) {}
                    field_name = after_ident[val_start..dot_j];
                }

                // Enum value access: EnumName.Value
                if (defined_enums.get(ident)) |enum_def| {
                    if (field_name.len > 0) {
                        var found = false;
                        for (enum_def.members.items) |m| {
                            if (std.mem.eql(u8, m, field_name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            const ln = findLineNumber(src, line);
                            std.log.err("{s}:{d}: error: enum '{s}' has no value '{s}'", .{ file_path, ln, ident, field_name });
                            return SemaError.InvalidEnumValue;
                        }
                    }
                }

                // Struct field access: var.field
                if (symtab.lookup(ident)) |sym_entry| {
                    if (sym_entry.type_name) |vtype| {
                        if (defined_structs.get(vtype)) |struct_def| {
                            if (field_name.len > 0) {
                                var found = false;
                                for (struct_def.fields.items) |f| {
                                    if (std.mem.eql(u8, f.name, field_name)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    const ln = findLineNumber(src, line);
                                    std.log.err("{s}:{d}: error: struct '{s}' has no field '{s}'", .{ file_path, ln, vtype, field_name });
                                    return SemaError.InvalidStructField;
                                }
                            }
                        }
                    }
                }

                i += dot_j;
                continue;
            }

            if (isKeyword(ident)) continue;
            if (isType(ident)) continue;
            if (isBuiltin(ident)) continue;
            if (isOperator(ident)) continue;

            if (symtab.lookup(ident) == null) {
                const ln = findLineNumber(src, line);
                std.log.err("{s}:{d}: error: undefined variable '{s}'", .{ file_path, ln, ident });
                return SemaError.UndefinedVariable;
            }
        } else {
            i += 1;
        }
    }
}

const CallInfo = struct {
    name: []const u8,
    args: []const u8,
};

fn findFunctionCall(line: []const u8) ?CallInfo {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            if (i < line.len) i += 1;
            continue;
        }
        if (std.ascii.isAlphabetic(line[i]) or line[i] == '_') {
            const start = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) : (i += 1) {}
            const ident = line[start..i];
            if (isControlKeywordForCall(ident)) continue;
            const rest = std.mem.trimLeft(u8, line[i..], " \t");
            if (rest.len > 0 and rest[0] == '(') {
                const paren_offset = line.len - rest.len;
                const close = findMatchingParen(line, paren_offset) orelse return null;
                const args = line[paren_offset + 1 .. close];
                return .{ .name = ident, .args = args };
            }
        }
        i += 1;
    }
    return null;
}

fn isControlKeywordForCall(ident: []const u8) bool {
    const kws = [_][]const u8{ "if", "while", "for", "else", "match", "return", "defer" };
    for (kws) |kw| {
        if (std.mem.eql(u8, ident, kw)) return true;
    }
    return false;
}

fn findMatchingParen(line: []const u8, open_pos: usize) ?usize {
    if (open_pos >= line.len or line[open_pos] != '(') return null;
    var depth: i32 = 0;
    var i = open_pos;
    while (i < line.len) {
        if (line[i] == '(') depth += 1;
        if (line[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        if (line[i] == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) {}
        }
        i += 1;
    }
    return null;
}

fn countArgs(args_str: []const u8) usize {
    const trimmed = std.mem.trim(u8, args_str, " \t\r\n");
    if (trimmed.len == 0) return 0;
    var count: usize = 1;
    var depth: i32 = 0;
    var in_string = false;
    for (trimmed) |c| {
        if (c == '"') in_string = !in_string;
        if (in_string) continue;
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c == ',' and depth == 0) count += 1;
    }
    return count;
}

fn isControlKeyword(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "return")) return true;
    if (std.mem.startsWith(u8, trimmed, "else")) return true;
    if (std.mem.startsWith(u8, trimmed, "defer")) return true;
    if (std.mem.startsWith(u8, trimmed, "match")) return true;
    return false;
}

fn isKeyword(ident: []const u8) bool {
    const kws = [_][]const u8{
        "state", "entry", "fn", "var", "if", "else", "while", "return", "print",
        "free", "struct", "enum", "import", "on", "always", "run", "break",
        "continue", "defer", "for", "match", "true", "false", "null",
    };
    for (kws) |kw| {
        if (std.mem.eql(u8, ident, kw)) return true;
    }
    return false;
}

fn isType(ident: []const u8) bool {
    const types = [_][]const u8{
        "int", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64",
        "f32", "f64", "bool", "void", "string", "ptr",
    };
    for (types) |t| {
        if (std.mem.eql(u8, ident, t)) return true;
    }
    return false;
}

fn isBuiltin(ident: []const u8) bool {
    const builtins = [_][]const u8{
        "print", "free", "malloc", "ptr_load", "ptr_store",
        "reinterpret_cast", "addr", "sizeof", "alignof",
        "GetStdHandle", "WriteConsoleA", "ReadConsoleA",
        "ExitProcess", "GetLastError", "VirtualAlloc",
        "LoadLibraryA", "GetProcAddress",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, ident, b)) return true;
    }
    return false;
}

fn findBraceBlockSimple(s: []const u8) ?struct { start: usize, end: usize } {
    var depth: i32 = 0;
    var open_idx: ?usize = null;
    for (s, 0..) |ch, i| {
        if (ch == '{') {
            if (depth == 0) open_idx = i;
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                return .{ .start = open_idx.?, .end = i };
            }
        }
    }
    return null;
}

fn extractVarName(rest: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, rest, " \t\r\n");
    const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=');
    const colon_idx = std.mem.indexOfScalar(u8, trimmed, ':');
    const end_idx = if (eq_idx) |ei| blk: {
        break :blk if (colon_idx) |ci| @min(ei, ci) else ei;
    } else if (colon_idx) |ci| ci else trimmed.len;
    return std.mem.trim(u8, trimmed[0..end_idx], " \t\r\n");
}

fn extractVarType(rest: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, rest, " \t\r\n");
    const colon_idx = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    const after_colon = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t\r\n");
    var end: usize = 0;
    while (end < after_colon.len and std.ascii.isAlphanumeric(after_colon[end])) : (end += 1) {}
    if (end == 0) return null;
    return after_colon[0..end];
}

fn validateTypeRef(
    type_name: []const u8,
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    if (isType(type_name)) return;
    if (defined_structs.contains(type_name)) return;
    if (defined_enums.contains(type_name)) return;
    const ln = findLineNumber(src, type_name);
    std.log.err("{s}:{d}: error: undefined type '{s}'", .{ file_path, ln, type_name });
    return SemaError.UndefinedStruct;
}

fn isOperator(ident: []const u8) bool {
    const ops = [_][]const u8{
        "+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=",
        "&&", "||", "!", "&", "|", "^", "~", "<<", ">>",
    };
    for (ops) |op| {
        if (std.mem.eql(u8, ident, op)) return true;
    }
    return false;
}

// ── Phase 1: Type Inference & Type Checking ──

fn inferTypeFromLiteral(text: []const u8) ast.TypeId {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .unknown;

    if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false")) return .bool_type;
    if (std.mem.eql(u8, trimmed, "null")) return .ptr_type;

    if (trimmed[0] == '"') return .string_type;

    if (std.ascii.isDigit(trimmed[0]) or (trimmed[0] == '-' and trimmed.len > 1 and std.ascii.isDigit(trimmed[1]))) {
        if (std.mem.indexOfScalar(u8, trimmed, '.') != null) return .f64_type;
        if (std.mem.indexOfScalar(u8, trimmed, 'x') != null) return .u64_type;
        return .i64_type;
    }

    return .unknown;
}

fn inferTypeFromExpr(
    expr: []const u8,
    symtab: *scope_mod.ScopeTable,
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    defined_funcs: *const std.StringHashMap(ast.EntryDecl),
) ast.TypeId {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return .unknown;

    const literal = inferTypeFromLiteral(trimmed);
    if (literal != .unknown) return literal;

    // Parenthesized expression: (expr)
    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
        return inferTypeFromExpr(trimmed[1 .. trimmed.len - 1], symtab, defined_structs, defined_enums, defined_funcs);
    }

    // Unary minus: -expr
    if (trimmed[0] == '-' and trimmed.len > 1 and std.ascii.isDigit(trimmed[1])) {
        return inferTypeFromLiteral(trimmed[1..]);
    }

    // Check if it's a known variable via symbol table
    if (symtab.lookup(trimmed)) |sym_entry| {
        if (sym_entry.type_id != .unknown) return sym_entry.type_id;
        if (sym_entry.type_name) |tn| return ast.TypeId.fromName(tn);
    }

    // Function call: look up return type from defined_funcs
    if (findFunctionCall(trimmed)) |call_info| {
        if (defined_funcs.get(call_info.name)) |func_def| {
            if (func_def.return_type) |rt| {
                return ast.TypeId.fromName(rt);
            }
            return .void;
        }
        if (std.mem.eql(u8, call_info.name, "print")) return .void;
        if (std.mem.eql(u8, call_info.name, "malloc")) return .ptr_type;
        if (std.mem.eql(u8, call_info.name, "addr")) return .ptr_type;
        return .unknown;
    }

    // Dot access: EnumName.Value or var.field
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot_idx| {
        if (dot_idx > 0 and dot_idx + 1 < trimmed.len) {
            const obj_name = std.mem.trim(u8, trimmed[0..dot_idx], " \t\r\n");
            const field_name = std.mem.trim(u8, trimmed[dot_idx + 1 ..], " \t\r\n");
            if (defined_enums.get(obj_name)) |_| {
                return .enum_type;
            }
            if (symtab.lookup(obj_name)) |sym_entry| {
                if (sym_entry.type_name) |vtype| {
                    if (defined_structs.get(vtype)) |struct_def| {
                        for (struct_def.fields.items) |f| {
                            if (std.mem.eql(u8, f.name, field_name)) {
                                return ast.TypeId.fromName(f.type_name);
                            }
                        }
                    }
                }
            }
        }
    }

    // Check for binary expression (a + b, a - b, etc.)
    const ops = [_][]const u8{ "+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=" };
    for (ops) |op| {
        if (findBinOp(trimmed, op)) |parts| {
            const left_type = inferTypeFromExpr(parts.left, symtab, defined_structs, defined_enums, defined_funcs);
            const right_type = inferTypeFromExpr(parts.right, symtab, defined_structs, defined_enums, defined_funcs);
            if (left_type == .unknown) return right_type;
            if (right_type == .unknown) return left_type;
            if (left_type == right_type) return left_type;
            if (left_type.isNumeric() and right_type.isNumeric()) return .f64_type;
            return .unknown;
        }
    }

    return .unknown;
}

const BinOpParts = struct {
    left: []const u8,
    right: []const u8,
};

fn findBinOp(expr: []const u8, op: []const u8) ?BinOpParts {
    var depth: i32 = 0;
    var i: usize = expr.len;
    while (i > 0) {
        i -= 1;
        const c = expr[i];
        if (c == ')') depth += 1;
        if (c == '(') depth -= 1;
        if (depth != 0) continue;

        if (i + op.len <= expr.len and std.mem.eql(u8, expr[i .. i + op.len], op)) {
            if (i == 0) return null;
            if (i + op.len >= expr.len) return null;
            const left = std.mem.trim(u8, expr[0..i], " \t\r\n");
            const right = std.mem.trim(u8, expr[i + op.len ..], " \t\r\n");
            if (left.len > 0 and right.len > 0) return .{ .left = left, .right = right };
        }
    }
    return null;
}

fn checkTypeAssignment(
    line: []const u8,
    symtab: *scope_mod.ScopeTable,
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    defined_funcs: *const std.StringHashMap(ast.EntryDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    // "var x: Type = expr" — check if expr type matches Type
    if (std.mem.startsWith(u8, trimmed, "var ")) {
        const rest = trimmed["var ".len..];
        const vtype = extractVarType(rest);
        const eq_idx = std.mem.indexOfScalar(u8, rest, '=');
        if (vtype != null and eq_idx != null) {
            const declared = ast.TypeId.fromName(vtype.?);
            const expr_str = std.mem.trim(u8, rest[eq_idx.? + 1 ..], " \t\r\n");
            const inferred = inferTypeFromExpr(expr_str, symtab, defined_structs, defined_enums, defined_funcs);
            if (declared != .unknown and inferred != .unknown and declared != inferred) {
                if (!(declared.isInt() and inferred == .i64_type) and
                    !(declared.isFloat() and inferred.isNumeric()))
                {
                    const ln = findLineNumber(src, line);
                    std.log.err("{s}:{d}: error: type mismatch: cannot assign '{s}' to variable of type '{s}'", .{ file_path, ln, inferred.name(), declared.name() });
                    return SemaError.TypeError;
                }
            }
        }
    }

    // "x = expr" — check if expr type matches x's declared type
    if (!std.mem.startsWith(u8, trimmed, "var ")) {
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
            const lhs = std.mem.trim(u8, trimmed[0..eq_idx], " \t\r\n");
            if (lhs.len > 0 and !std.mem.containsAtLeast(u8, lhs, 1, " ")) {
                if (symtab.lookup(lhs)) |sym_entry| {
                    if (sym_entry.type_name) |type_name| {
                        const declared = ast.TypeId.fromName(type_name);
                        const expr_str = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\r\n");
                        const inferred = inferTypeFromExpr(expr_str, symtab, defined_structs, defined_enums, defined_funcs);
                        if (declared != .unknown and inferred != .unknown and declared != inferred) {
                            if (!(declared.isInt() and inferred == .i64_type) and
                                !(declared.isFloat() and inferred.isNumeric()))
                            {
                                const ln = findLineNumber(src, line);
                                std.log.err("{s}:{d}: error: type mismatch: cannot assign '{s}' to variable of type '{s}'", .{ file_path, ln, inferred.name(), declared.name() });
                                return SemaError.TypeError;
                            }
                        }
                    }
                }
            }
        }
    }
}

// ── Phase 1: Function argument type checking ──

fn splitArgs(allocator: Allocator, args_str: []const u8) std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);
    const trimmed = std.mem.trim(u8, args_str, " \t\r\n");
    if (trimmed.len == 0) return result;

    var depth: i32 = 0;
    var in_string = false;
    var start: usize = 0;
    for (trimmed, 0..) |c, i| {
        if (c == '"') in_string = !in_string;
        if (in_string) continue;
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c == ',' and depth == 0) {
            result.append(std.mem.trim(u8, trimmed[start..i], " \t\r\n")) catch {};
            start = i + 1;
        }
    }
    result.append(std.mem.trim(u8, trimmed[start..], " \t\r\n")) catch {};
    return result;
}

fn checkFuncArgTypes(
    allocator: Allocator,
    call_info: CallInfo,
    func_def: *const ast.EntryDecl,
    symtab: *scope_mod.ScopeTable,
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    defined_funcs: *const std.StringHashMap(ast.EntryDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    if (func_def.params.items.len == 0) return;

    var args_list = splitArgs(allocator, call_info.args);
    defer args_list.deinit();

    for (args_list.items, 0..) |arg, idx| {
        if (idx >= func_def.params.items.len) break;
        const param = func_def.params.items[idx];
        const param_type = ast.TypeId.fromName(param.type_name);
        const arg_type = inferTypeFromExpr(arg, symtab, defined_structs, defined_enums, defined_funcs);
        if (param_type != .unknown and arg_type != .unknown and param_type != arg_type) {
            if (!(param_type.isInt() and arg_type == .i64_type) and
                !(param_type.isFloat() and arg_type.isNumeric()))
            {
                const ln = findLineNumber(src, call_info.name);
                std.log.err("{s}:{d}: error: function '{s}' argument {d}: expected '{s}' but got '{s}'", .{ file_path, ln, call_info.name, idx + 1, param_type.name(), arg_type.name() });
                return SemaError.ArgTypeMismatch;
            }
        }
    }
}

// ── Phase 1: Binary operation type mismatch checking ──

fn checkBinaryTypeMismatch(
    line: []const u8,
    symtab: *scope_mod.ScopeTable,
    defined_structs: *const std.StringHashMap(ast.StructDef),
    defined_enums: *const std.StringHashMap(ast.EnumDecl),
    defined_funcs: *const std.StringHashMap(ast.EntryDecl),
    file_path: []const u8,
    src: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    var expr_to_check = trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
        var last_eq = eq_idx;
        var j: usize = eq_idx + 1;
        while (j < trimmed.len) {
            if (trimmed[j] == '"') {
                j += 1;
                while (j < trimmed.len and trimmed[j] != '"') j += 1;
                if (j < trimmed.len) j += 1;
                continue;
            }
            if (trimmed[j] == '=' and j + 1 < trimmed.len and trimmed[j + 1] != '=') {
                last_eq = j;
            }
            j += 1;
        }
        expr_to_check = std.mem.trim(u8, trimmed[last_eq + 1 ..], " \t\r\n");
    }

    const type_mismatch_ops = [_][]const u8{ "+", "-", "*", "/" };
    for (type_mismatch_ops) |op| {
        if (findBinOp(expr_to_check, op)) |parts| {
            const left_type = inferTypeFromExpr(parts.left, symtab, defined_structs, defined_enums, defined_funcs);
            const right_type = inferTypeFromExpr(parts.right, symtab, defined_structs, defined_enums, defined_funcs);
            if (left_type != .unknown and right_type != .unknown and left_type != right_type) {
                if (!(left_type.isNumeric() and right_type.isNumeric())) {
                    const ln = findLineNumber(src, line);
                    std.log.err("{s}:{d}: error: binary op '{s}' cannot apply to '{s}' and '{s}'", .{ file_path, ln, op, left_type.name(), right_type.name() });
                    return SemaError.BinaryTypeMismatch;
                }
            }
        }
    }
}

fn findLineNumber(src: []const u8, needle: []const u8) u32 {
    if (needle.len == 0 or src.len == 0) return 0;
    if (std.mem.indexOf(u8, src, needle)) |offset| {
        var ln: u32 = 1;
        var i: usize = 0;
        while (i < offset) : (i += 1) {
            if (src[i] == '\n') ln += 1;
        }
        return ln;
    }
    return 0;
}
