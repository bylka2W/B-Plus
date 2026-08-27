const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const hir_arena = @import("arena.zig");
const item_mod = @import("item.zig");
const body_mod = @import("body.zig");
const expr_mod = @import("expr.zig");
const stmt_mod = @import("stmt.zig");
const pattern_mod = @import("pattern.zig");
const literal_mod = @import("literal.zig");
const ids_mod = @import("../foundation/ids/ids.zig");

const HirArena = hir_arena.HirArena;
const HirItem = item_mod.HirItem;
const HirItemKind = item_mod.HirItem.HirItemKind;
const HirBody = body_mod.HirBody;
const HirExpr = expr_mod.HirExpr;
const HirExprKind = expr_mod.HirExpr.HirExprKind;
const HirStmt = stmt_mod.HirStmt;
const HirStmtKind = stmt_mod.HirStmt.HirStmtKind;
const HirPattern = pattern_mod.HirPattern;
const HirPatternKind = pattern_mod.HirPattern.HirPatternKind;
const HirLiteral = literal_mod.HirLiteral;
const HirTy = hir_arena.HirTy;
const BinOp = expr_mod.BinOp;
const UnaryOp = expr_mod.UnaryOp;
const LocalKind = stmt_mod.LocalKind;
const Visibility = item_mod.HirItem.HirItemKind.Visibility;

const ExprId = ids_mod.ExprId;
const StmtId = ids_mod.StmtId;
const ItemId = ids_mod.ItemId;
const BodyId = ids_mod.BodyId;
const PatId = ids_mod.PatId;
const DefId = ids_mod.DefId;
const SymbolId = ids_mod.SymbolId;
const TypeId = ids_mod.TypeId;
const OwnerId = ids_mod.OwnerId;
const LabelId = ids_mod.LabelId;

pub const ConvertError = error{
    OutOfMemory,
    InvalidSyntax,
    UnsupportedConstruct,
};

pub const ProgramNodeToHir = struct {
    allocator: Allocator,
    program: *const ast.ProgramNode,
    hir: *HirArena,
    sema: *const SemaView,

    name_to_def: std.StringHashMap(DefId),
    next_def: u32,
    next_sym: u32,

    pub const SemaView = struct {
        func_names: []const []const u8,
        struct_names: []const []const u8,
        enum_names: []const []const u8,

        pub fn fromSemaResult(sema: *const @import("../sema/sema.zig").SemaResult) SemaView {
            return .{
                .func_names = sema.defined_func_names.items,
                .struct_names = sema.defined_struct_names.items,
                .enum_names = sema.defined_enum_names.items,
            };
        }

        pub fn isFunction(self: *const SemaView, name: []const u8) bool {
            for (self.func_names) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
            return false;
        }

        pub fn isStruct(self: *const SemaView, name: []const u8) bool {
            for (self.struct_names) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
            return false;
        }

        pub fn isEnum(self: *const SemaView, name: []const u8) bool {
            for (self.enum_names) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
            return false;
        }
    };

    pub fn init(allocator: Allocator, program: *const ast.ProgramNode, hir: *HirArena, sema: *const SemaView) ProgramNodeToHir {
        return .{
            .allocator = allocator,
            .program = program,
            .hir = hir,
            .sema = sema,
            .name_to_def = std.StringHashMap(DefId).init(allocator),
            .next_def = 1,
            .next_sym = 1,
        };
    }

    pub fn deinit(self: *ProgramNodeToHir) void {
        self.name_to_def.deinit();
    }

    pub fn convert(self: *ProgramNodeToHir) ConvertError!void {
        const p = self.program;
        try self.registerBuiltins();
        for (p.common.func_defs.items) |*f| try self.lowerFunction(f);
        for (p.metal.entries.items) |*e| try self.lowerEntry(e);
        for (p.plan.states.items) |*s| try self.lowerState(s);
        for (p.metal.kernels.items) |*k| try self.lowerKernel(k);
    }

    fn registerBuiltins(self: *ProgramNodeToHir) ConvertError!void {
        const builtins = [_]struct { name: []const u8, ret_ty: []const u8 }{
            .{ .name = "print", .ret_ty = "void" },
        };
        for (builtins) |b| {
            const def_id = try self.getOrCreateDef(b.name);
            const ret_ty = self.typeNameToId(b.ret_ty);
            _ = self.hir.addItem(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .kind = .{ .extern_fn = .{
                    .name = SymbolId.INVALID,
                    .name_bytes = try self.hir.allocator().dupe(u8, b.name),
                    .def_id = def_id,
                    .params = &.{},
                    .return_type = ret_ty,
                    .visibility = .public,
                } },
            });
        }
    }

    fn allocDef(self: *ProgramNodeToHir) DefId {
        const id = self.next_def;
        self.next_def += 1;
        return DefId.new(id);
    }

    fn allocSym(self: *ProgramNodeToHir) SymbolId {
        const id = self.next_sym;
        self.next_sym += 1;
        return SymbolId.new(id);
    }

    fn getOrCreateDef(self: *ProgramNodeToHir, name: []const u8) !DefId {
        if (self.name_to_def.get(name)) |d| return d;
        const d = self.allocDef();
        try self.name_to_def.put(name, d);
        return d;
    }

    fn lowerFunction(self: *ProgramNodeToHir, func: *const ast.EntryDecl) ConvertError!void {
        const def_id = try self.getOrCreateDef(func.name);
        const sym_id = self.allocSym();
        const ret_ty = self.typeNameToId(func.return_type);

        var params = std.ArrayList(HirItemKind.Param).init(self.hir.allocator());
        for (func.params.items) |*p| {
            const p_def = self.allocDef();
            const p_sym = self.allocSym();
            try params.append(.{
                .name = p_sym,
                .def_id = p_def,
                .ty = self.typeNameToId(p.type_name),
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
        }

                var bb = BodyBuilder{
                    .allocator = self.allocator,
                    .hir = self.hir,
                    .bridge = self,
                    .def_scope = std.StringHashMap(DefId).init(self.allocator),
                    .func_return_types = std.StringHashMap(TypeId).init(self.allocator),
                    .in_loop = false,
                    .stmt_depth = 0,
                    .local_count = 0,
                };
        defer bb.def_scope.deinit();
        defer bb.func_return_types.deinit();

        for (params.items, 0..) |hp, i| {
            try bb.def_scope.put(func.params.items[i].name, hp.def_id);
        }

        const body_lines = func.body_lines.items;
        const body_expr = try self.lowerBodyStr(&bb, body_lines);

        const body = HirBody{ .owner = OwnerId.new(def_id.index), .entry = body_expr, .local_count = @intCast(bb.local_count) };
        const body_id_final = self.hir.addBody(body);

        const item = HirItem{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .fn_decl = .{
                .name = sym_id,
                .name_bytes = func.name,
                .def_id = def_id,
                .params = params.toOwnedSlice() catch return error.OutOfMemory,
                .return_type = ret_ty,
                .body = body_id_final,
                .visibility = .public,
            } },
        };
        _ = self.hir.addItem(item);
    }

    fn lowerEntry(self: *ProgramNodeToHir, entry: *const ast.EntryDecl) ConvertError!void {
        try self.lowerFunction(entry);
    }

    fn lowerState(self: *ProgramNodeToHir, state: *const ast.StateDefNode) ConvertError!void {
        const def_id = try self.getOrCreateDef(state.name);
        const sym_id = self.allocSym();

        var fields = std.ArrayList(HirItemKind.StateVar).init(self.hir.allocator());
        for (state.variables.items) |*v| {
            try fields.append(.{
                .name = self.allocSym(),
                .ty = self.typeNameToId(v.type_name),
                .default = null,
            });
        }

        var transitions = std.ArrayList(HirItemKind.Transition).init(self.hir.allocator());
        for (state.transitions.items) |*t| {
            const t_def = try self.getOrCreateDef(t.target);
            try transitions.append(.{
                .event = if (t.event_name) |_| blk: {
                    const e_sym = self.allocSym();
                    break :blk e_sym;
                } else null,
                .target = t_def,
                .guard = null,
                .priority = if (t.hot_weight) |hw| @intFromFloat(hw) else 0,
                .attrs = &.{},
            });
        }

        var entry_body: ?BodyId = null;
        if (state.enter_body) |body_str| {
            if (std.mem.trim(u8, body_str, " \t\r\n").len > 0) {
                var bb = BodyBuilder{
                    .allocator = self.allocator,
                    .hir = self.hir,
                    .bridge = self,
                    .def_scope = std.StringHashMap(DefId).init(self.allocator),
                    .func_return_types = std.StringHashMap(TypeId).init(self.allocator),
                    .in_loop = false,
                    .stmt_depth = 0,
                    .local_count = 0,
                };
                defer bb.def_scope.deinit();
                defer bb.func_return_types.deinit();
                const lines = [_][]const u8{body_str};
                const entry_expr = try self.lowerBodyStr(&bb, &lines);
                const body = HirBody{ .owner = OwnerId.new(def_id.index), .entry = entry_expr, .local_count = @intCast(bb.local_count) };
                entry_body = self.hir.addBody(body);
            }
        }

        var exit_body: ?BodyId = null;
        if (state.exit_body) |body_str| {
            if (std.mem.trim(u8, body_str, " \t\r\n").len > 0) {
                var bb = BodyBuilder{
                    .allocator = self.allocator,
                    .hir = self.hir,
                    .bridge = self,
                    .def_scope = std.StringHashMap(DefId).init(self.allocator),
                    .func_return_types = std.StringHashMap(TypeId).init(self.allocator),
                    .in_loop = false,
                    .stmt_depth = 0,
                    .local_count = 0,
                };
                defer bb.def_scope.deinit();
                defer bb.func_return_types.deinit();
                const lines = [_][]const u8{body_str};
                const exit_expr = try self.lowerBodyStr(&bb, &lines);
                const body = HirBody{ .owner = OwnerId.new(def_id.index), .entry = exit_expr, .local_count = @intCast(bb.local_count) };
                exit_body = self.hir.addBody(body);
            }
        }

        const item = HirItem{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .state_item = .{
                .name = sym_id,
                .def_id = def_id,
                .attrs = &.{},
                .fields = fields.toOwnedSlice() catch return error.OutOfMemory,
                .entry = entry_body,
                .exit = exit_body,
                .transitions = transitions.toOwnedSlice() catch return error.OutOfMemory,
                .parent = null,
                .visibility = .public,
            } },
        };
        _ = self.hir.addItem(item);
    }

    fn lowerKernel(self: *ProgramNodeToHir, kernel: *const ast.KernelDecl) ConvertError!void {
        const def_id = try self.getOrCreateDef(kernel.name);
        const sym_id = self.allocSym();

        const item = HirItem{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .kernel_item = .{
                .name = sym_id,
                .def_id = def_id,
                .attrs = &.{},
                .entries = &.{},
                .bindings = &.{},
                .dispatch = .{ .x = 1, .y = 1, .z = 1 },
                .visibility = .public,
            } },
        };
        _ = self.hir.addItem(item);
    }

    fn typeNameToId(self: *ProgramNodeToHir, type_name: ?[]const u8) TypeId {
        const name = type_name orelse return TypeId.INVALID;
        const builtin_kind: ?HirTy.BuiltinKind = if (std.mem.eql(u8, name, "void"))
            .void_type
        else if (std.mem.eql(u8, name, "bool"))
            .bool
        else if (std.mem.eql(u8, name, "i8"))
            .i8
        else if (std.mem.eql(u8, name, "i16"))
            .i16
        else if (std.mem.eql(u8, name, "i32"))
            .i32
        else if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "int"))
            .i64
        else if (std.mem.eql(u8, name, "u8"))
            .u8
        else if (std.mem.eql(u8, name, "u16"))
            .u16
        else if (std.mem.eql(u8, name, "u32"))
            .u32
        else if (std.mem.eql(u8, name, "u64"))
            .u64
        else if (std.mem.eql(u8, name, "f32"))
            .f32
        else if (std.mem.eql(u8, name, "f64"))
            .f64
        else if (std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "str"))
            .str
        else if (std.mem.eql(u8, name, "never"))
            .never
        else if (std.mem.eql(u8, name, "char"))
            .char_type
        else
            null;

        if (builtin_kind) |bk| {
            return self.hir.addType(.{ .builtin = .{ .kind = bk } });
        }

        // Check for user-defined types
        if (self.sema.isStruct(name) or self.sema.isEnum(name)) {
            const sym = self.allocSym();
            // Create a named type reference — the HirTy.named stores a SymbolId
            return self.hir.addType(.{ .named = .{ .name = sym, .args = &.{} } });
        }

        return TypeId.INVALID;
    }

    fn lowerBodyStr(self: *ProgramNodeToHir, bb: *BodyBuilder, lines: []const []const u8) ConvertError!ExprId {
        if (lines.len == 0) return self.makeMissingExpr();

        var stmts = std.ArrayList(StmtId).init(self.hir.allocator());
        for (lines) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '{' or trimmed[0] == '}') continue;
            try self.lowerStmtLine(bb, trimmed, &stmts);
        }

        // Pop the last statement if it's an expr, and use its expression as the block result.
        // This avoids the same expression being lowered twice (once as a stmt, once as the result).
        const last_result = if (stmts.items.len > 0) blk: {
            const last = self.hir.getStmt(stmts.items[stmts.items.len - 1]) orelse break :blk self.makeMissingExpr();
            if (last.kind == .expr) {
                const result = last.kind.expr.expr;
                _ = stmts.pop();
                break :blk result;
            }
            break :blk self.makeMissingExpr();
        } else self.makeMissingExpr();

        return self.hir.addExpr(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .ty = TypeId.INVALID,
            .kind = .{ .block = .{
                .stmts = stmts.toOwnedSlice() catch return error.OutOfMemory,
                .result = last_result,
            } },
        });
    }

    fn lowerStmtLine(self: *ProgramNodeToHir, bb: *BodyBuilder, line: []const u8, stmts: *std.ArrayList(StmtId)) ConvertError!void {
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) return;

        if (std.mem.startsWith(u8, t, "return")) {
            const rest = std.mem.trim(u8, t["return".len..], " \t\r\n");
            const val = if (rest.len > 0) try self.lowerExprStr(bb, rest) else self.makeMissingExpr();
            try stmts.append(self.hir.addStmt(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .kind = .{ .return_stmt = .{ .value = val } },
            }));
            return;
        }

        if (std.mem.startsWith(u8, t, "var ")) {
            const rest = std.mem.trim(u8, t["var ".len..], " \t\r\n");
            const name = extractName(rest);
            if (name.len == 0) return;

            const p_def = self.allocDef();
            try bb.def_scope.put(name, p_def);

            var var_ty: ?TypeId = null;
            if (extractVarType(rest)) |vt| {
                var_ty = self.typeNameToId(vt);
            }

            var init_expr: ?ExprId = null;
            if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
                const expr_str = std.mem.trim(u8, rest[eq + 1 ..], " \t\r\n");
                init_expr = try self.lowerExprStr(bb, expr_str);
            }

            const pat = self.hir.addPattern(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .kind = .{ .binding = .{
                    .def = p_def,
                    .sub_pattern = PatId.INVALID,
                    .ty = var_ty orelse TypeId.INVALID,
                    .mutable = true,
                } },
            });

            bb.local_count += 1;

            try stmts.append(self.hir.addStmt(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .kind = .{ .local_decl = .{
                    .kind = .@"var",
                    .pattern = pat,
                    .type_annotation = var_ty,
                    .init = init_expr,
                } },
            }));
            return;
        }

        if (std.mem.startsWith(u8, t, "if ") or std.mem.startsWith(u8, t, "if(")) {
            try self.lowerIfStmt(bb, t, stmts);
            return;
        }

        if (std.mem.startsWith(u8, t, "while ") or std.mem.startsWith(u8, t, "while(")) {
            try self.lowerWhileStmt(bb, t, stmts);
            return;
        }

        if (std.mem.indexOfScalar(u8, t, '=')) |eq_idx| {
            const lhs = std.mem.trim(u8, t[0..eq_idx], " \t\r\n");
            const rhs = std.mem.trim(u8, t[eq_idx + 1 ..], " \t\r\n");
            const looks_like_assign = lhs.len > 0 and rhs.len > 0 and
                std.mem.indexOfScalar(u8, lhs, '(') == null and
                std.mem.indexOfScalar(u8, lhs, '"') == null;
            if (looks_like_assign) {
                const target = try self.lowerExprStr(bb, lhs);
                const val = try self.lowerExprStr(bb, rhs);
                const assign_expr = self.hir.addExpr(.{
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                    .ty = TypeId.INVALID,
                    .kind = .{ .assign = .{ .target = target, .value = val } },
                });
                try stmts.append(self.hir.addStmt(.{
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                    .kind = .{ .expr = .{ .expr = assign_expr } },
                }));
                return;
            }
        }

        const expr = try self.lowerExprStr(bb, t);
        try stmts.append(self.hir.addStmt(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .expr = .{ .expr = expr } },
        }));
    }

    fn lowerIfStmt(self: *ProgramNodeToHir, bb: *BodyBuilder, line: []const u8, stmts: *std.ArrayList(StmtId)) ConvertError!void {
        const rest = std.mem.trim(u8, line[3..], " \t\r\n");
        const cb = findBraceBlock(rest) orelse return;
        const cond_str = std.mem.trim(u8, rest[0..cb.body_start - 1], " \t\r\n");
        const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

        const cond = try self.lowerExprStr(bb, cond_str);
        var then_stmts = std.ArrayList(StmtId).init(self.hir.allocator());
        try self.parseBodyStr(bb, body_str, &then_stmts);
        const then_block = self.hir.addStmt(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .block = .{ .stmts = then_stmts.toOwnedSlice() catch return error.OutOfMemory } },
        });

        const else_block: ?StmtId = null;

        try stmts.append(self.hir.addStmt(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .if_stmt = .{
                .condition = cond,
                .then_branch = then_block,
                .else_branch = else_block,
            } },
        }));
    }

    fn lowerWhileStmt(self: *ProgramNodeToHir, bb: *BodyBuilder, line: []const u8, stmts: *std.ArrayList(StmtId)) ConvertError!void {
        const rest = std.mem.trim(u8, line[6..], " \t\r\n");
        const cb = findBraceBlock(rest) orelse return;
        const cond_str = std.mem.trim(u8, rest[0..cb.body_start - 1], " \t\r\n");
        const body_str = std.mem.trim(u8, rest[cb.body_start..cb.body_end], " \t\r\n");

        const cond = try self.lowerExprStr(bb, cond_str);
        var body_stmts = std.ArrayList(StmtId).init(self.hir.allocator());
        try self.parseBodyStr(bb, body_str, &body_stmts);
        const body_block = self.hir.addStmt(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .block = .{ .stmts = body_stmts.toOwnedSlice() catch return error.OutOfMemory } },
        });

        const saved = bb.in_loop;
        bb.in_loop = true;
        try stmts.append(self.hir.addStmt(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .kind = .{ .while_stmt = .{
                .condition = cond,
                .body = body_block,
            } },
        }));
        bb.in_loop = saved;
    }

    fn parseBodyStr(self: *ProgramNodeToHir, bb: *BodyBuilder, body: []const u8, stmts: *std.ArrayList(StmtId)) ConvertError!void {
        var pos: usize = 0;
        while (pos < body.len) {
            while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\r' or body[pos] == '\n')) : (pos += 1) {}
            if (pos >= body.len) break;
            if (body[pos] == '{' or body[pos] == '}') {
                pos += 1;
                continue;
            }

            var depth: i32 = 0;
            var in_str = false;
            var start = pos;
            while (pos < body.len) {
                const c = body[pos];
                if (c == '"') in_str = !in_str;
                if (in_str) {
                    pos += 1;
                    continue;
                }
                if (c == '(' or c == '{') depth += 1;
                if (c == ')' or c == '}') {
                    depth -= 1;
                    if (depth < 0) {
                        pos += 1;
                        break;
                    }
                }
                if (c == ';' and depth == 0) {
                    const stmt = std.mem.trim(u8, body[start..pos], " \t\r\n");
                    pos += 1;
                    start = pos;
                    if (stmt.len > 0) try self.lowerStmtLine(bb, stmt, stmts);
                    break;
                }
                pos += 1;
            }
            if (pos >= body.len or (pos == body.len)) {
                if (start < body.len) {
                    const stmt = std.mem.trim(u8, body[start..body.len], " \t\r\n");
                    if (stmt.len > 0) try self.lowerStmtLine(bb, stmt, stmts);
                }
                break;
            }
        }
    }

    fn lowerExprStr(self: *ProgramNodeToHir, bb: *BodyBuilder, expr: []const u8) ConvertError!ExprId {
        const t = std.mem.trim(u8, expr, " \t\r\n");
        if (t.len == 0) return self.makeMissingExpr();

        if (std.mem.eql(u8, t, "true")) {
            return self.hir.addExpr(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .ty = TypeId.INVALID,
                .kind = .{ .literal = .{ .value = .{ .boolean = true } } },
            });
        }
        if (std.mem.eql(u8, t, "false")) {
            return self.hir.addExpr(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .ty = TypeId.INVALID,
                .kind = .{ .literal = .{ .value = .{ .boolean = false } } },
            });
        }

        if (t.len > 0 and t[0] == '"') {
            const end = std.mem.lastIndexOfScalar(u8, t, '"') orelse t.len;
            const content = try self.hir.allocator().dupe(u8, t[1..end]);
            return self.hir.addExpr(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .ty = TypeId.INVALID,
                .kind = .{ .literal = .{ .value = .{ .string = content } } },
            });
        }

        if (std.ascii.isDigit(t[0]) or (t.len > 1 and t[0] == '-' and std.ascii.isDigit(t[1]))) {
            const val = if (std.mem.indexOfScalar(u8, t, '.') != null)
                HirLiteral{ .float = std.fmt.parseFloat(f64, t) catch 0.0 }
            else
                HirLiteral{ .int = std.fmt.parseInt(i64, t, 10) catch 0 };
            return self.hir.addExpr(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .ty = TypeId.INVALID,
                .kind = .{ .literal = .{ .value = val } },
            });
        }

        if (t[0] == '(') {
            if (findParenEnd(t, 0)) |end| {
                if (end == t.len - 1) return self.lowerExprStr(bb, t[1..end]);
            }
        }

        if (std.mem.indexOfScalar(u8, t, '(')) |pp| {
            if (pp > 0) {
                const nm = std.mem.trim(u8, t[0..pp], " \t\r\n");
                if (findParenEnd(t, pp)) |c| {
                    return self.lowerCallExpr(bb, nm, std.mem.trim(u8, t[pp + 1 .. c], " \t\r\n"));
                }
            }
        }

        const ops = [_]struct { []const u8, BinOp }{
            .{ "+", .add }, .{ "-", .sub }, .{ "*", .mul },
            .{ "/", .div }, .{ "%", .mod },
            .{ "==", .eq }, .{ "!=", .ne },
            .{ "<=", .le }, .{ ">=", .ge },
            .{ "<", .lt },  .{ ">", .gt },
            .{ "&&", .and_ }, .{ "||", .or_ },
        };
        for (ops) |pair| {
            if (findBinOp(t, pair[0])) |parts| {
                const left = try self.lowerExprStr(bb, parts.left);
                const right = try self.lowerExprStr(bb, parts.right);
                return self.hir.addExpr(.{
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                    .ty = TypeId.INVALID,
                    .kind = .{ .binary = .{ .op = pair[1], .left = left, .right = right } },
                });
            }
        }

        if (t[0] == '-' and t.len > 1) {
            const inner = try self.lowerExprStr(bb, t[1..]);
            return self.hir.addExpr(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .ty = TypeId.INVALID,
                .kind = .{ .unary = .{ .op = .negate, .operand = inner } },
            });
        }

        if (bb.def_scope.get(t)) |d| {
            return self.hir.addExpr(.{
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .ty = TypeId.INVALID,
                .kind = .{ .path = .{ .def = d } },
            });
        }

        return self.makePath(t);
    }

    fn lowerCallExpr(self: *ProgramNodeToHir, bb: *BodyBuilder, name: []const u8, args_str: []const u8) ConvertError!ExprId {
        var args = std.ArrayList(ExprId).init(self.hir.allocator());
        if (args_str.len > 0) {
            var depth: i32 = 0;
            var in_str = false;
            var start: usize = 0;
            for (args_str, 0..) |c, i| {
                if (c == '"') in_str = !in_str;
                if (in_str) continue;
                if (c == '(') depth += 1;
                if (c == ')') depth -= 1;
                if (c == ',' and depth == 0) {
                    const a = std.mem.trim(u8, args_str[start..i], " \t\r\n");
                    if (a.len > 0) {
                        try args.append(try self.lowerExprStr(bb, a));
                    }
                    start = i + 1;
                }
            }
            const last = std.mem.trim(u8, args_str[start..], " \t\r\n");
            if (last.len > 0) {
                try args.append(try self.lowerExprStr(bb, last));
            }
        }

        const callee = try self.makePath(name);
        return self.hir.addExpr(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .ty = TypeId.INVALID,
            .kind = .{ .call = .{
                .callee = callee,
                .args = args.toOwnedSlice() catch return error.OutOfMemory,
            } },
        });
    }

    fn makePath(self: *ProgramNodeToHir, name: []const u8) ConvertError!ExprId {
        const d = self.name_to_def.get(name) orelse DefId.INVALID;
        return self.hir.addExpr(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .ty = TypeId.INVALID,
            .kind = .{ .path = .{ .def = d } },
        });
    }

    fn makeMissingExpr(self: *ProgramNodeToHir) ExprId {
        return self.hir.addExpr(.{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .ty = TypeId.INVALID,
            .kind = .missing,
        });
    }
};

const BodyBuilder = struct {
    allocator: Allocator,
    hir: *HirArena,
    bridge: *ProgramNodeToHir,
    def_scope: std.StringHashMap(DefId),
    func_return_types: std.StringHashMap(TypeId),
    in_loop: bool,
    stmt_depth: u32,
    local_count: u32,
};

fn extractName(rest: []const u8) []const u8 {
    const t = std.mem.trim(u8, rest, " \t\r\n");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isAlphanumeric(t[end]) or t[end] == '_')) : (end += 1) {}
    return t[0..end];
}

fn extractVarType(rest: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, rest, " \t\r\n");
    const colon_idx = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const after_colon = std.mem.trim(u8, t[colon_idx + 1 ..], " \t\r\n");
    var end: usize = 0;
    while (end < after_colon.len and std.ascii.isAlphanumeric(after_colon[end])) : (end += 1) {}
    if (end == 0) return null;
    const type_str = std.mem.trimRight(u8, after_colon[0..end], " \t\r\n");
    if (type_str.len == 0) return null;
    return type_str;
}

const BraceBlock = struct { body_start: usize, body_end: usize };

fn findBraceBlock(text: []const u8) ?BraceBlock {
    var i: usize = 0;
    while (i < text.len and text[i] != '{') : (i += 1) {}
    if (i >= text.len) return null;
    const body_start = i + 1;
    var depth: i32 = 1;
    i = body_start;
    while (i < text.len and depth > 0) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') depth -= 1;
        i += 1;
    }
    // Unterminated block (`{` at end of line, no `}` on this line): treat the
    // rest of the line as the body instead of returning an inverted slice.
    const body_end = if (depth > 0) text.len else i - 1;
    if (body_start > body_end or body_end > text.len) return null;
    return .{ .body_start = body_start, .body_end = body_end };
}

const BinParts = struct { left: []const u8, right: []const u8 };

fn findBinOp(expr: []const u8, op: []const u8) ?BinParts {
    var depth: i32 = 0;
    var i: usize = expr.len;
    while (i > 0) {
        i -= 1;
        if (expr[i] == ')') depth += 1;
        if (expr[i] == '(') depth -= 1;
        if (depth != 0) continue;
        if (i + op.len > expr.len) continue;
        if (!std.mem.eql(u8, expr[i .. i + op.len], op)) continue;
        if (i == 0) return null;
        if (i + op.len >= expr.len) return null;
        if (std.mem.eql(u8, op, "=") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "!") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "<") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, ">") and i + 1 < expr.len and expr[i + 1] == '=') continue;
        if (std.mem.eql(u8, op, "&") and i + 1 < expr.len and expr[i + 1] == '&') continue;
        if (std.mem.eql(u8, op, "|") and i + 1 < expr.len and expr[i + 1] == '|') continue;
        const left = std.mem.trim(u8, expr[0..i], " \t\r\n");
        const right = std.mem.trim(u8, expr[i + op.len ..], " \t\r\n");
        if (left.len > 0 and right.len > 0) return .{ .left = left, .right = right };
    }
    return null;
}

fn findParenEnd(line: []const u8, open: usize) ?usize {
    if (open >= line.len or line[open] != '(') return null;
    var depth: i32 = 0;
    var i = open;
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
