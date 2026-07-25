const std = @import("std");
const types_mod = @import("types.zig");
const TypeData = types_mod.TypeData;
const TypeId = types_mod.TypeId;
const BuiltinKind = types_mod.BuiltinKind;
const Mutability = types_mod.Mutability;
const engine_mod = @import("engine.zig");
const TypeEngine = engine_mod.TypeEngine;
const ids = @import("../foundation/ids/ids.zig");

pub const TypeBuilder = struct {
    engine: *TypeEngine,

    pub const BuiltinTypes = struct {
        i32_ty: TypeId,
        i64_ty: TypeId,
        u32_ty: TypeId,
        u64_ty: TypeId,
        f32_ty: TypeId,
        f64_ty: TypeId,
        bool_ty: TypeId,
        str_ty: TypeId,
        char_ty: TypeId,
        void_ty: TypeId,
        never_ty: TypeId,
        i8_ty: TypeId,
        i16_ty: TypeId,
        u8_ty: TypeId,
        u16_ty: TypeId,
    };

    pub fn builtins(self: *TypeBuilder) BuiltinTypes {
        return .{
            .i32_ty = self.engine.builtin(.i32_type),
            .i64_ty = self.engine.builtin(.i64_type),
            .u32_ty = self.engine.builtin(.u32_type),
            .u64_ty = self.engine.builtin(.u64_type),
            .f32_ty = self.engine.builtin(.f32_type),
            .f64_ty = self.engine.builtin(.f64_type),
            .bool_ty = self.engine.builtin(.bool_type),
            .str_ty = self.engine.builtin(.str_type),
            .char_ty = self.engine.builtin(.char_type),
            .void_ty = self.engine.builtin(.void_type),
            .never_ty = self.engine.builtin(.never_type),
            .i8_ty = self.engine.builtin(.i8_type),
            .i16_ty = self.engine.builtin(.i16_type),
            .u8_ty = self.engine.builtin(.u8_type),
            .u16_ty = self.engine.builtin(.u16_type),
        };
    }

    pub fn ref(self: *TypeBuilder, mutable: Mutability, referent: TypeId) TypeId {
        return self.engine.type_arena.reference(mutable, referent);
    }

    pub fn ptr(self: *TypeBuilder, mutable: Mutability, pointee: TypeId) TypeId {
        return self.engine.type_arena.pointer(mutable, pointee);
    }

    pub fn sliceOf(self: *TypeBuilder, element: TypeId) TypeId {
        return self.engine.type_arena.slice(element);
    }

    pub fn arrayOf(self: *TypeBuilder, element: TypeId, len: u64) TypeId {
        return self.engine.type_arena.array(element, len);
    }

    pub fn tupleOf(self: *TypeBuilder, elements: []const TypeId) TypeId {
        return self.engine.type_arena.tuple(elements);
    }

    pub fn fnOf(self: *TypeBuilder, params: []const TypeId, ret: TypeId) TypeId {
        return self.engine.type_arena.fnPtr(params, ret, false);
    }

    pub fn optionalOf(self: *TypeBuilder, inner: TypeId) TypeId {
        return self.engine.type_arena.optional(inner);
    }

    pub fn errorUnionOf(self: *TypeBuilder, ok: TypeId, err: TypeId) TypeId {
        return self.engine.type_arena.errorUnion(ok, err);
    }

    pub fn adt(self: *TypeBuilder, def_id: ids.DefId, args: []const TypeId) TypeId {
        return self.engine.type_arena.adt(def_id, args);
    }

    pub fn param(self: *TypeBuilder, index: u32, name: ids.SymbolId) TypeId {
        return self.engine.type_arena.typeParam(index, name);
    }

    pub fn inferVar(self: *TypeBuilder) TypeId {
        return self.engine.freshVar();
    }

    pub fn never(self: *TypeBuilder) TypeId {
        return self.engine.type_arena.never();
    }

    pub fn unit(self: *TypeBuilder) TypeId {
        return self.engine.type_arena.unit();
    }
};

test "TypeBuilder: builtins" {
    var engine = TypeEngine.init(std.testing.allocator);
    defer engine.deinit();

    var builder = TypeBuilder{ .engine = &engine };
    const bt = builder.builtins();

    try std.testing.expect(bt.i32_ty.isValid());
    try std.testing.expect(bt.bool_ty.isValid());
    try std.testing.expect(bt.str_ty.isValid());
}

test "TypeBuilder: compound types" {
    var engine = TypeEngine.init(std.testing.allocator);
    defer engine.deinit();

    var builder = TypeBuilder{ .engine = &engine };
    const bt = builder.builtins();

    const ref_i32 = builder.ref(.@"const", bt.i32_ty);
    try std.testing.expect(ref_i32.isValid());

    const slice_bool = builder.sliceOf(bt.bool_ty);
    try std.testing.expect(slice_bool.isValid());

    const arr = builder.arrayOf(bt.i32_ty, 5);
    try std.testing.expect(arr.isValid());

    const params = [_]TypeId{ bt.i32_ty, bt.bool_ty };
    const fn_ty = builder.fnOf(&params, bt.void_ty);
    try std.testing.expect(fn_ty.isValid());

    const opt = builder.optionalOf(bt.i32_ty);
    try std.testing.expect(opt.isValid());
}

test "TypeBuilder: inference var unification" {
    var engine = TypeEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.initInference();

    var builder = TypeBuilder{ .engine = &engine };
    const bt = builder.builtins();

    const v = builder.inferVar();
    try engine.unify(v, bt.i64_ty, 0);
    try std.testing.expect(engine.resolve(v).eql(bt.i64_ty));
}
