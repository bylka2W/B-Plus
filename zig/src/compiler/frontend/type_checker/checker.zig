const std = @import("std");

const ids = @import("../foundation/ids/ids.zig");
const hir_mod = @import("../hir/arena.zig");

const HirArena = hir_mod.HirArena;
const HirItem = hir_mod.HirItem;
const HirExpr = hir_mod.HirExpr;
const HirStmt = hir_mod.HirStmt;
const HirPattern = hir_mod.HirPattern;
const HirTy = hir_mod.HirTy;

const HirBuiltinKind = @import("../hir/ty.zig").HirTy.BuiltinKind;

const type_sys = @import("../type_system/type_system.zig");
const TypeEngine = type_sys.TypeEngine;
const TypeId = type_sys.TypeId;
const TypeData = type_sys.TypeData;
const BuiltinKind = type_sys.BuiltinKind;

const errors_mod = @import("errors.zig");
const ErrorList = errors_mod.ErrorList;

const SourceSpan = @import("../source/location/span.zig").SourceSpan;

pub const HirExprId = ids.ExprId;
pub const HirStmtId = ids.StmtId;
pub const HirItemId = ids.ItemId;
pub const HirPatId = ids.PatId;
pub const HirBodyId = ids.BodyId;
pub const DefId = ids.DefId;

pub const TypeCheckError = error{
    TypeError,
    OutOfMemory,
};

pub const LoopContext = struct {
    break_type: TypeId,
    depth: u32,
};

pub const TypeChecker = struct {
    hir: *HirArena,
    engine: *TypeEngine,
    errors: *ErrorList,
    def_table: *const @import("../resolver/def.zig").DefTable,

    symbols: []const []const u8,
    builtin_print: DefId,

    def_types: std.AutoHashMap(DefId, TypeId),
    nominal_types: std.AutoHashMap(DefId, TypeId),
    struct_items: std.AutoHashMap(DefId, HirItem.HirItemKind.StructItem),
    enum_items: std.AutoHashMap(DefId, HirItem.HirItemKind.EnumItem),

    current_return_type: TypeId,

    in_loop: bool,
    loop_stack: std.ArrayList(LoopContext),
    loop_depth: u32,

    in_fn_body: bool,
    fn_has_return: bool,

    pub usingnamespace @import("expr_checker.zig");
    pub usingnamespace @import("stmt_checker.zig");
    pub usingnamespace @import("body_checker.zig");

    pub fn init(
        hir: *HirArena,
        engine: *TypeEngine,
        errors: *ErrorList,
        def_table: *const @import("../resolver/def.zig").DefTable,
        symbols: []const []const u8,
    ) TypeChecker {
        return .{
            .hir = hir,
            .engine = engine,
            .errors = errors,
            .def_table = def_table,

            .symbols = symbols,
            .builtin_print = DefId.INVALID,

            .def_types = std.AutoHashMap(DefId, TypeId).init(
                engine.backing_alloc,
            ),
            .nominal_types = std.AutoHashMap(DefId, TypeId).init(
                engine.backing_alloc,
            ),
            .struct_items = std.AutoHashMap(DefId, HirItem.HirItemKind.StructItem).init(
                engine.backing_alloc,
            ),
            .enum_items = std.AutoHashMap(DefId, HirItem.HirItemKind.EnumItem).init(
                engine.backing_alloc,
            ),

            .current_return_type = TypeId.INVALID,

            .in_loop = false,
            .loop_stack = std.ArrayList(LoopContext).init(
                engine.backing_alloc,
            ),
            .loop_depth = 0,

            .in_fn_body = false,
            .fn_has_return = false,
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.def_types.deinit();
        self.nominal_types.deinit();
        self.struct_items.deinit();
        self.enum_items.deinit();
        self.loop_stack.deinit();
    }

    pub fn check(self: *TypeChecker) TypeCheckError!void {
        var i: u32 = 0;

        while (i < self.hir.itemCount()) : (i += 1) {
            const item_id = HirItemId.new(i);

            const item = self.hir.getItem(item_id) orelse continue;

            self.registerItemType(item);
        }

        i = 0;
        while (i < self.hir.itemCount()) : (i += 1) {
            const item_id = HirItemId.new(i);

            const item = self.hir.getItem(item_id) orelse continue;

            try self.checkItem(item);
        }
    }

    fn registerItemType(
        self: *TypeChecker,
        item: HirItem,
    ) void {
        switch (item.kind) {
.fn_decl => |f| {
                var params = std.ArrayList(TypeId).init(self.engine.backing_alloc);
                defer params.deinit();
                for (f.params) |param| {
                    params.append(self.hirTypeToTypeId(param.ty)) catch return;
                }
const ret_ty = if (f.return_type.isValid()) self.hirTypeToTypeId(f.return_type) else TypeId.INVALID;
                self.defineDef(
                    f.def_id,
                    self.engine.type_arena.fnPtr(params.items, ret_ty, false),
                );
            },
            .struct_item => |s| {
                self.struct_items.put(s.def_id, s) catch {};
                const ty = self.engine.type_arena.adt(s.def_id, &.{});
                self.nominal_types.put(s.def_id, ty) catch {};
                self.defineDef(s.def_id, ty);
            },
            .enum_item => |e| {
                self.enum_items.put(e.def_id, e) catch {};
                const ty = self.engine.type_arena.adt(e.def_id, &.{});
                self.nominal_types.put(e.def_id, ty) catch {};
                self.defineDef(e.def_id, ty);
            },
            .state_item => |st| {
                self.defineDef(st.def_id, self.engine.freshVar());
            },
            .kernel_item,
            .trait_item,
            .impl_item,
            .const_item,
            .type_alias,
            .extern_fn,
            .missing => {},
        }
    }

    pub fn checkItem(
        self: *TypeChecker,
        item: HirItem,
    ) TypeCheckError!void {
        switch (item.kind) {
            .fn_decl => |f| {
                try self.checkFnItem(f);
            },

            .state_item => |st| {
                try self.checkStateItem(st);
            },

            .kernel_item,
            .struct_item,
            .enum_item,
            .trait_item,
            .impl_item,
            .const_item,
            .type_alias,
            .extern_fn,
            .missing => {},
        }
    }

    pub fn checkFnItem(
        self: *TypeChecker,
        f: HirItem.HirItemKind.FnItem,
    ) TypeCheckError!void {
        for (f.params) |param| {
            const param_ty = self.hirTypeToTypeId(param.ty);
            if (param.def_id.isValid()) {
                self.defineDef(param.def_id, param_ty);
            }
        }

        const ret_ty = if (f.return_type.isValid()) self.hirTypeToTypeId(f.return_type) else TypeId.INVALID;

        const prev_return = self.current_return_type;
        const prev_in_fn = self.in_fn_body;
        const prev_has_return = self.fn_has_return;

        self.current_return_type = ret_ty;
        self.in_fn_body = true;
        self.fn_has_return = false;

        if (f.body.isValid()) {
            if (self.hir.getBody(f.body)) |body| {
                try self.checkBody(body);
            }
        }

        const has_declared_ret = f.return_type.isValid();
        if (has_declared_ret and !self.fn_has_return) {
            if (!self.isVoid(ret_ty)) {
                self.reportError(.{ .missing_return = .{} }, SourceSpan{ .file_id = 0, .start = 0, .end = 0 });
            }
        }

        self.current_return_type = prev_return;
        self.in_fn_body = prev_in_fn;
        self.fn_has_return = prev_has_return;
    }

    pub fn checkStateItem(
        self: *TypeChecker,
        state: HirItem.HirItemKind.StateItem,
    ) TypeCheckError!void {
        const span = SourceSpan{ .file_id = 0, .start = 0, .end = 0 };
        self.defineDef(state.def_id, self.engine.freshVar());

        for (state.fields) |field| {
            const field_ty = self.hirTypeToTypeId(field.ty);
            if (field.default) |init_id| {
                const init_ty = try self.checkExpr(init_id);
                _ = self.engine.unify(field_ty, init_ty, 0) catch {
                    self.reportError(.{ .type_mismatch = .{
                        .expected = self.builtinTypeName(field_ty),
                        .found = self.builtinTypeName(init_ty),
                    } }, span);
                };
            }
            self.defineDef(field.def_id, field_ty);
        }

        for (state.transitions) |t| {
            if (!t.target.isValid()) {
                self.reportError(.{ .undefined_state_target = {} }, span);
                continue;
            }
            const is_state = if (self.def_table.getDef(t.target)) |d|
                d.kind == .state
            else
                false;
            if (!is_state) {
                self.reportError(.{ .undefined_state_target = {} }, span);
            }
        }

        if (state.entry == null) {
            self.reportError(.{ .missing_state_entry = {} }, span);
        }

        const prev_return = self.current_return_type;
        const prev_in_fn = self.in_fn_body;

        self.current_return_type = self.engine.builtin(.void_type);
        self.in_fn_body = false;

        if (state.entry) |body_id| {
            if (self.hir.getBody(body_id)) |body| {
                try self.checkBody(body);
            }
        }
        if (state.exit) |body_id| {
            if (self.hir.getBody(body_id)) |body| {
                try self.checkBody(body);
            }
        }

        self.current_return_type = prev_return;
        self.in_fn_body = prev_in_fn;
    }

    pub fn defineDef(
        self: *TypeChecker,
        def: DefId,
        ty: TypeId,
    ) void {
        self.def_types.put(def, ty) catch return;
    }

    pub fn setBuiltinPrint(
        self: *TypeChecker,
        def: DefId,
    ) void {
        if (!def.isValid()) return;
        self.builtin_print = def;
        const fn_ty = self.engine.type_arena.fnPtr(
            &.{self.engine.freshVar()},
            self.engine.builtin(.void_type),
            false,
        );
        self.defineDef(def, fn_ty);
    }

    pub fn lookupDef(
        self: *const TypeChecker,
        def: DefId,
    ) ?TypeId {
        if (def.eql(DefId.INVALID)) {
            return null;
        }

        return self.def_types.get(def);
    }

    pub fn reportError(
        self: *TypeChecker,
        kind: errors_mod.TypeError.ErrorKind,
        span: SourceSpan,
    ) void {
        self.errors.report(kind, span);
    }

    pub fn setExprType(
        self: *TypeChecker,
        expr_id: HirExprId,
        ty: TypeId,
    ) void {
        if (self.hir.getExpr(expr_id)) |expr| {
            self.hir.exprs.items[expr_id.index] = .{
                .span = expr.span,
                .ty = ty,
                .kind = expr.kind,
            };
        }
    }

    pub fn hirTypeToTypeId(
        self: *TypeChecker,
        hir_ty: TypeId,
    ) TypeId {
        const ty_data = self.hir.getType(hir_ty) orelse {
            return self.engine.freshVar();
        };

        return switch (ty_data) {
            .builtin => |b| {
                return self.engine.builtin(
                    hirBuiltinToTypeSys(b.kind),
                );
            },

            .named => |n| {
                return self.namedTypeToTypeId(n.name);
            },

            .pointer => |p| {
                const inner = self.hirTypeToTypeId(p.pointee);

                return self.engine.type_arena.pointer(
                    if (p.mutable) .mut else .@"const",
                    inner,
                );
            },

            .slice => |s| {
                return self.engine.type_arena.slice(
                    self.hirTypeToTypeId(s.element),
                );
            },

            .array => |a| {
                return self.engine.type_arena.array(
                    self.hirTypeToTypeId(a.element),
                    a.length,
                );
            },

            .tuple => |t| {
                var elems = std.ArrayList(TypeId).init(
                    self.engine.backing_alloc,
                );

                for (t.elements) |e| {
                    elems.append(
                        self.hirTypeToTypeId(e),
                    ) catch {
                        return self.engine.freshVar();
                    };
                }

                return self.engine.type_arena.tuple(
                    elems.items,
                );
            },

            .fn_type => |f| {
                var params = std.ArrayList(TypeId).init(
                    self.engine.backing_alloc,
                );

                for (f.params) |p| {
                    params.append(
                        self.hirTypeToTypeId(p),
                    ) catch {
                        return self.engine.freshVar();
                    };
                }

                return self.engine.type_arena.fnPtr(
                    params.items,
                    self.hirTypeToTypeId(f.ret),
                    false,
                );
            },

            .generic,
            .inference_var,
            .missing => {
                return self.engine.freshVar();
            },

            .optional => |o| {
                return self.engine.type_arena.optional(
                    self.hirTypeToTypeId(o.inner),
                );
            },

            .error_union => |eu| {
                return self.engine.type_arena.errorUnion(
                    self.hirTypeToTypeId(eu.ok),
                    self.hirTypeToTypeId(eu.err),
                );
            },
        };
    }

    pub fn builtinFromName(text: []const u8) ?BuiltinKind {
        const map = .{
            .{ "bool", BuiltinKind.bool_type },
            .{ "i8", BuiltinKind.i8_type },
            .{ "i16", BuiltinKind.i16_type },
            .{ "i32", BuiltinKind.i32_type },
            .{ "i64", BuiltinKind.i64_type },
            .{ "u8", BuiltinKind.u8_type },
            .{ "u16", BuiltinKind.u16_type },
            .{ "u32", BuiltinKind.u32_type },
            .{ "u64", BuiltinKind.u64_type },
            .{ "f32", BuiltinKind.f32_type },
            .{ "f64", BuiltinKind.f64_type },
            .{ "void", BuiltinKind.void_type },
            .{ "string", BuiltinKind.str_type },
            .{ "str", BuiltinKind.str_type },
            .{ "char", BuiltinKind.char_type },
            .{ "int", BuiltinKind.i32_type },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, text, entry[0])) return entry[1];
        }
        return null;
    }

    fn namedTypeToTypeId(
        self: *TypeChecker,
        name: ids.SymbolId,
    ) TypeId {
        if (TypeChecker.builtinFromName(self.symbolText(name))) |b| {
            return self.engine.builtin(b);
        }
        if (self.def_table.lookupName(name)) |def_id| {
            if (self.nominal_types.get(def_id)) |ty| {
                return ty;
            }
            if (self.def_table.getDef(def_id)) |d| {
                if (d.kind == .struct_type or d.kind == .enum_type) {
                    const ty = self.engine.type_arena.adt(def_id, &.{});
                    self.nominal_types.put(def_id, ty) catch {};
                    return ty;
                }
            }
        }
        self.reportError(.{ .unresolved_type = .{
            .name = self.symbolText(name),
        } }, .{ .file_id = 0, .start = 0, .end = 0 });
        return self.engine.freshVar();
    }

    pub fn symbolText(
        self: *const TypeChecker,
        sym: ids.SymbolId,
    ) []const u8 {
        if (!sym.isValid()) return "";
        if (sym.index >= self.symbols.len) return "";
        return self.symbols[sym.index];
    }

    pub fn isVoid(
        self: *const TypeChecker,
        ty: TypeId,
    ) bool {
        const resolved = self.engine.resolve(ty);
        if (self.engine.get(resolved)) |data| {
            return data == .builtin and data.builtin == .void_type;
        }
        return false;
    }

    pub fn isScalar(
        self: *const TypeChecker,
        ty: TypeId,
    ) bool {
        const resolved = self.engine.resolve(ty);
        if (self.engine.get(resolved)) |data| {
            return data == .builtin;
        }
        return false;
    }

    pub fn unifyBool(
        self: *TypeChecker,
        cond_ty: TypeId,
        expr_id: HirExprId,
    ) bool {
        if (self.engine.unify(cond_ty, self.engine.builtin(.bool_type), 0)) |_| {
            return true;
        } else |_| {
            const span = if (self.hir.getExpr(expr_id)) |e| e.span else SourceSpan{ .file_id = 0, .start = 0, .end = 0 };
            self.reportError(.{ .condition_not_bool = {} }, span);
            return false;
        }
    }

    fn hirBuiltinToTypeSys(
        k: HirBuiltinKind,
    ) type_sys.BuiltinKind {
        return switch (k) {
            .bool => .bool_type,

            .i8 => .i8_type,
            .i16 => .i16_type,
            .i32 => .i32_type,
            .i64 => .i64_type,

            .u8 => .u8_type,
            .u16 => .u16_type,
            .u32 => .u32_type,
            .u64 => .u64_type,

            .f32 => .f32_type,
            .f64 => .f64_type,

            .void_type => .void_type,
            .never => .never_type,

            .str => .str_type,
            .char_type => .char_type,
        };
    }

    pub fn builtinTypeName(
        self: *const TypeChecker,
        ty: TypeId,
    ) []const u8 {
        if (self.engine.get(ty)) |data| {
            return switch (data) {
                .builtin => |b| switch (b) {
                    .i8_type => "i8",
                    .i16_type => "i16",
                    .i32_type => "i32",
                    .i64_type => "i64",

                    .u8_type => "u8",
                    .u16_type => "u16",
                    .u32_type => "u32",
                    .u64_type => "u64",

                    .f32_type => "f32",
                    .f64_type => "f64",

                    .bool_type => "bool",
                    .void_type => "void",
                    .never_type => "!",
                    .str_type => "str",
                    .char_type => "char",
                },

                .infer_var => "<?>",
                .unit => "()",
                .never => "!",

                else => "<type>",
            };
        }

        return "<unknown>";
    }

    pub fn pushLoop(
        self: *TypeChecker,
    ) void {
        self.loop_depth += 1;

        self.loop_stack.append(.{
            .break_type = self.engine.freshVar(),
            .depth = self.loop_depth,
        }) catch {};

        self.in_loop = true;
    }

    pub fn popLoop(
        self: *TypeChecker,
    ) void {
        if (self.loop_stack.items.len > 0) {
            _ = self.loop_stack.pop();

            if (self.loop_depth > 0) {
                self.loop_depth -= 1;
            }
        }

        self.in_loop = self.loop_stack.items.len > 0;
    }

    pub fn currentBreakType(
        self: *const TypeChecker,
    ) ?TypeId {
        if (self.loop_stack.items.len == 0) {
            return null;
        }

        return self.loop_stack.items[
            self.loop_stack.items.len - 1
        ].break_type;
    }

    pub fn currentLoopDepth(
        self: *const TypeChecker,
    ) u32 {
        return self.loop_depth;
    }

    pub fn isInsideLoop(
        self: *const TypeChecker,
    ) bool {
        return self.loop_stack.items.len > 0;
    }
};

const TypeError = errors_mod.TypeError;
