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
    def_types: std.AutoHashMap(DefId, TypeId),
    current_return_type: TypeId,
    in_loop: bool,
    loop_stack: std.ArrayList(LoopContext),
    loop_depth: u32,

    pub usingnamespace @import("expr_checker.zig");
    pub usingnamespace @import("stmt_checker.zig");
    pub usingnamespace @import("body_checker.zig");

    pub fn init(hir: *HirArena, engine: *TypeEngine, errors: *ErrorList, def_table: *const @import("../resolver/def.zig").DefTable) TypeChecker {
        return .{
            .hir = hir,
            .engine = engine,
            .errors = errors,
            .def_table = def_table,
            .def_types = std.AutoHashMap(DefId, TypeId).init(engine.backing_alloc),
            .current_return_type = TypeId.INVALID,
            .in_loop = false,
            .loop_stack = std.ArrayList(LoopContext).init(engine.backing_alloc),
            .loop_depth = 0,
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.def_types.deinit();
        self.loop_stack.deinit();
    }

    pub fn check(self: *TypeChecker) TypeCheckError!void {
        var i: u32 = 0;
        while (i < self.hir.itemCount()) : (i += 1) {
            const item_id = HirItemId.new(i);
            const item = self.hir.getItem(item_id) orelse continue;
            try self.checkItem(item);
        }
    }

    pub fn checkItem(self: *TypeChecker, item: HirItem) TypeCheckError!void {
        switch (item.kind) {
            .fn_decl => |f| try self.checkFnItem(f),
            .struct_item, .enum_item, .trait_item, .impl_item, .const_item, .type_alias, .extern_fn, .missing => {},
        }
    }

    pub fn checkFnItem(self: *TypeChecker, f: HirItem.HirItemKind.FnItem) TypeCheckError!void {
        for (f.params) |param| {
            const param_ty = self.hirTypeToTypeId(param.ty);
            if (self.def_table.lookupName(param.name)) |def_id| {
                self.defineDef(def_id, param_ty);
            }
        }
        const ret_ty = self.hirTypeToTypeId(f.return_type);
        const prev_return = self.current_return_type;
        self.current_return_type = ret_ty;

        if (f.body.isValid()) {
            if (self.hir.getBody(f.body)) |body| {
                try self.checkBody(body);
            }
        }

        self.current_return_type = prev_return;
    }

    pub fn defineDef(self: *TypeChecker, def: DefId, ty: TypeId) void {
        self.def_types.put(def, ty) catch return;
    }

    pub fn lookupDef(self: *const TypeChecker, def: DefId) ?TypeId {
        return self.def_types.get(def);
    }

    pub fn reportError(self: *TypeChecker, kind: errors_mod.TypeError.ErrorKind, span: SourceSpan) void {
        self.errors.report(kind, span);
    }

    pub fn setExprType(self: *TypeChecker, expr_id: HirExprId, ty: TypeId) void {
        if (self.hir.getExpr(expr_id)) |expr| {
            self.hir.exprs.items[expr_id.index] = .{
                .span = expr.span,
                .ty = ty,
                .kind = expr.kind,
            };
        }
    }

    pub fn hirTypeToTypeId(self: *TypeChecker, hir_ty: TypeId) TypeId {
        const ty_data = self.hir.getType(hir_ty) orelse return self.engine.freshVar();
        return switch (ty_data) {
            .builtin => |b| self.engine.builtin(hirBuiltinToTypeSys(b.kind)),
            .named => |n| self.engine.builtin(self.symbolToBuiltin(n.name)),
            .pointer => |p| {
                const inner = self.hirTypeToTypeId(p.pointee);
                return self.engine.type_arena.pointer(if (p.mutable) .mut else .@"const", inner);
            },
            .slice => |s| self.engine.type_arena.slice(self.hirTypeToTypeId(s.element)),
            .array => |a| self.engine.type_arena.array(self.hirTypeToTypeId(a.element), a.length),
            .tuple => |t| {
                var elems = std.ArrayList(TypeId).init(self.engine.backing_alloc);
                for (t.elements) |e| {
                    elems.append(self.hirTypeToTypeId(e)) catch return self.engine.freshVar();
                }
                return self.engine.type_arena.tuple(elems.items);
            },
            .fn_type => |f| {
                var params = std.ArrayList(TypeId).init(self.engine.backing_alloc);
                for (f.params) |p| {
                    params.append(self.hirTypeToTypeId(p)) catch return self.engine.freshVar();
                }
                return self.engine.type_arena.fnPtr(params.items, self.hirTypeToTypeId(f.ret), false);
            },
            .generic, .inference_var, .missing => self.engine.freshVar(),
            .optional => |o| self.engine.type_arena.optional(self.hirTypeToTypeId(o.inner)),
            .error_union => |eu| self.engine.type_arena.errorUnion(self.hirTypeToTypeId(eu.ok), self.hirTypeToTypeId(eu.err)),
        };
    }

    pub fn symbolToBuiltin(_: *const TypeChecker, sym: ids.SymbolId) BuiltinKind {
        _ = sym;
        return .i32_type;
    }

    fn hirBuiltinToTypeSys(k: HirBuiltinKind) type_sys.BuiltinKind {
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

    pub fn builtinTypeName(self: *const TypeChecker, ty: TypeId) []const u8 {
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

    pub fn pushLoop(self: *TypeChecker) void {
        self.loop_depth += 1;
        self.loop_stack.append(.{
            .break_type = self.engine.freshVar(),
            .depth = self.loop_depth,
        }) catch {};
        self.in_loop = true;
    }

    pub fn popLoop(self: *TypeChecker) void {
        if (self.loop_stack.items.len > 0) {
            _ = self.loop_stack.pop();
        }
        self.in_loop = self.loop_stack.items.len > 0;
    }

    pub fn currentBreakType(self: *const TypeChecker) ?TypeId {
        if (self.loop_stack.items.len == 0) return null;
        return self.loop_stack.items[self.loop_stack.items.len - 1].break_type;
    }

    pub fn currentLoopDepth(self: *const TypeChecker) u32 {
        return self.loop_depth;
    }

    pub fn isInsideLoop(self: *const TypeChecker) bool {
        return self.loop_stack.items.len > 0;
    }
};

const TypeError = errors_mod.TypeError;
