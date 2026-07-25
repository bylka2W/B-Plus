const std = @import("std");
const types_mod = @import("types.zig");
const TypeData = types_mod.TypeData;
const TypeId = types_mod.TypeId;
const TypeVarId = types_mod.TypeVarId;
const BuiltinKind = types_mod.BuiltinKind;
const arena_mod = @import("arena.zig");
const TypeArena = arena_mod.TypeArena;
const inference_mod = @import("inference.zig");
const TypeInference = inference_mod.TypeInference;
const substitute_mod = @import("substitute.zig");
const Substitution = substitute_mod.Substitution;
const constraints_mod = @import("constraints.zig");
const ConstraintSet = constraints_mod.ConstraintSet;

pub const TypeEngineError = error{
    TypeMismatch,
    OccursCheck,
    UnificationFailed,
    InfiniteType,
    OutOfMemory,
};

pub const TypeEngine = struct {
    type_arena: TypeArena,
    infer: TypeInference,
    constraints: ConstraintSet,
    backing_alloc: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) TypeEngine {
        const ta = TypeArena.init(backing);
        var te = TypeEngine{
            .type_arena = ta,
            .infer = undefined,
            .constraints = ConstraintSet.init(backing),
            .backing_alloc = backing,
        };
        te.infer = TypeInference.initWithAlloc(&te.type_arena, backing);
        return te;
    }

    pub fn initWithArena(arena_ptr: *TypeArena) TypeEngine {
        return .{
            .type_arena = arena_ptr.*,
            .infer = TypeInference.init(arena_ptr),
            .constraints = ConstraintSet.init(arena_ptr.allocator()),
            .backing_alloc = arena_ptr.allocator(),
        };
    }

    pub fn deinit(self: *TypeEngine) void {
        self.infer.deinit();
        self.constraints.deinit();
        self.type_arena.deinit();
    }

    pub fn initInference(self: *TypeEngine) void {
        self.infer.deinit();
        self.infer = TypeInference.init(&self.type_arena);
    }

    pub fn arena(self: *TypeEngine) *TypeArena {
        return &self.type_arena;
    }

    pub fn builtin(self: *TypeEngine, kind: BuiltinKind) TypeId {
        return self.type_arena.builtin(kind);
    }

    pub fn freshVar(self: *TypeEngine) TypeId {
        const var_id = self.infer.freshVar();
        return self.type_arena.inferVar(var_id);
    }

    pub fn resolve(self: *TypeEngine, ty: TypeId) TypeId {
        return self.infer.resolveType(ty);
    }

    pub fn unify(self: *TypeEngine, left: TypeId, right: TypeId, span: u32) TypeEngineError!void {
        try self.infer.constrainEqual(left, right, span);
    }

    pub fn addConstraint(self: *TypeEngine, c: constraints_mod.ConstraintSet.Constraint) !void {
        self.constraints.constraints.append(c) catch return error.OutOfMemory;
    }

    pub fn applySubstitution(self: *TypeEngine, sub: *const Substitution, ty: TypeId) TypeId {
        _ = self;
        return sub.apply(ty);
    }

    pub fn get(self: *const TypeEngine, id: TypeId) ?TypeData {
        return self.type_arena.get(id);
    }

    pub fn format(self: *const TypeEngine, ty: TypeId, writer: anytype) !void {
        const resolved = self.resolve(ty);
        try self.type_arena.format(resolved, writer);
    }

    pub fn typeCount(self: *const TypeEngine) u32 {
        return self.type_arena.count();
    }

    pub fn constraintCount(self: *const TypeEngine) u32 {
        return self.constraints.count();
    }
};

test "TypeEngine: basics" {
    var engine = TypeEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.initInference();

    const i32_ty = engine.builtin(.i32_type);
    const bool_ty = engine.builtin(.bool_type);
    const void_ty = engine.builtin(.void_type);

    try std.testing.expect(i32_ty.isValid());
    try std.testing.expect(bool_ty.isValid());

    const var_ty = engine.freshVar();
    try std.testing.expect(var_ty.isValid());
    try std.testing.expect(!engine.resolve(var_ty).eql(i32_ty));

    try engine.unify(var_ty, i32_ty, 0);
    const resolved = engine.resolve(var_ty);
    try std.testing.expect(resolved.eql(i32_ty));

    _ = void_ty;
}

test "TypeEngine: unify two vars" {
    var engine = TypeEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.initInference();

    const v0 = engine.freshVar();
    const v1 = engine.freshVar();
    const i32_ty = engine.builtin(.i32_type);

    try engine.unify(v0, i32_ty, 0);
    try engine.unify(v1, v0, 1);

    try std.testing.expect(engine.resolve(v1).eql(i32_ty));
}

test "TypeEngine: type count" {
    var engine = TypeEngine.init(std.testing.allocator);
    defer engine.deinit();

    _ = engine.builtin(.i32_type);
    _ = engine.builtin(.bool_type);
    _ = engine.builtin(.f64_type);

    try std.testing.expect(engine.typeCount() == 3);
}
