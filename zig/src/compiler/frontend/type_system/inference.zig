const std = @import("std");
const types_mod = @import("types.zig");
const TypeData = types_mod.TypeData;
const TypeId = types_mod.TypeId;
const TypeVarId = types_mod.TypeVarId;
const unify_mod = @import("unify.zig");
const UnificationTable = unify_mod.UnificationTable;
const arena_mod = @import("arena.zig");
const TypeArena = arena_mod.TypeArena;

pub const InferError = error{
    TypeMismatch,
    OccursCheck,
    UnificationFailed,
    InfiniteType,
    OutOfMemory,
};

pub const TypeInference = struct {
    type_arena: *TypeArena,
    table: UnificationTable,
    constraints: std.ArrayList(Constraint),

    pub const Constraint = union(enum) {
        eq: EqConstraint,
        subtype: EqConstraint,
        class: ClassConstraint,
    };

    pub const EqConstraint = struct {
        left: TypeId,
        right: TypeId,
        span: u32,
    };

    pub const ClassConstraint = struct {
        ty: TypeId,
        kind: ClassKind,
        span: u32,
    };

    pub const ClassKind = enum {
        numeric,
        integral,
        float_type,
        ordered,
        printable,
    };

    pub fn init(arena: *TypeArena) TypeInference {
        return .{
            .type_arena = arena,
            .table = UnificationTable.init(arena.allocator()),
            .constraints = std.ArrayList(Constraint).init(arena.allocator()),
        };
    }

    pub fn initWithAlloc(arena: *TypeArena, alloc: std.mem.Allocator) TypeInference {
        return .{
            .type_arena = arena,
            .table = UnificationTable.init(alloc),
            .constraints = std.ArrayList(Constraint).init(alloc),
        };
    }

    pub fn deinit(self: *TypeInference) void {
        self.table.deinit();
        self.constraints.deinit();
    }

    pub fn freshVar(self: *TypeInference) TypeVarId {
        return self.table.freshVar();
    }

    pub fn varToType(self: *TypeInference, var_id: TypeVarId) TypeId {
        return self.type_arena.inferVar(var_id);
    }

    pub fn constrainEqual(self: *TypeInference, left: TypeId, right: TypeId, span: u32) InferError!void {
        self.constraints.append(.{ .eq = .{ .left = left, .right = right, .span = span } }) catch return error.OutOfMemory;

        if (self.type_arena.get(left)) |l_data| {
            if (l_data == .infer_var) {
                try self.table.setKnown(l_data.infer_var.var_id, right);
                return;
            }
        }
        if (self.type_arena.get(right)) |r_data| {
            if (r_data == .infer_var) {
                try self.table.setKnown(r_data.infer_var.var_id, left);
                return;
            }
        }
        if (!left.eql(right)) return error.TypeMismatch;
    }

    pub fn addClassConstraint(self: *TypeInference, ty: TypeId, kind: ClassKind, span: u32) InferError!void {
        self.constraints.append(.{ .class = .{ .ty = ty, .kind = kind, .span = span } }) catch return error.OutOfMemory;
    }

    pub fn resolveType(self: *TypeInference, ty: TypeId) TypeId {
        const data = self.type_arena.get(ty) orelse return ty;
        return switch (data) {
            .infer_var => |iv| {
                if (self.table.findKnown(iv.var_id)) |known| {
                    return self.resolveType(known);
                }
                return ty;
            },
            .resolved_var => |rv| self.resolveType(rv),
            else => ty,
        };
    }

    pub fn isResolved(self: *TypeInference, ty: TypeId) bool {
        const resolved = self.resolveType(ty);
        if (self.type_arena.get(resolved)) |data| {
            if (data == .infer_var) return false;
            return true;
        }
        return true;
    }

    pub fn getInferVarId(self: *TypeInference, ty: TypeId) ?TypeVarId {
        const data = self.type_arena.get(ty) orelse return null;
        if (data == .infer_var) return data.infer_var.var_id;
        return null;
    }
};

test "TypeInference: fresh var and resolve" {
    var ta = TypeArena.init(std.testing.allocator);
    defer ta.deinit();
    var inf = TypeInference.init(&ta);
    defer inf.deinit();

    const v = inf.freshVar();
    const ty = inf.varToType(v);
    try std.testing.expect(ty.isValid());
    try std.testing.expect(!inf.isResolved(ty));
}

test "TypeInference: constrain equal with var" {
    var ta = TypeArena.init(std.testing.allocator);
    defer ta.deinit();
    var inf = TypeInference.init(&ta);
    defer inf.deinit();

    const v = inf.freshVar();
    const var_ty = inf.varToType(v);
    const i32_ty = ta.builtin(.i32_type);

    try inf.constrainEqual(var_ty, i32_ty, 0);

    const resolved = inf.resolveType(var_ty);
    try std.testing.expect(resolved.eql(i32_ty));
    try std.testing.expect(inf.isResolved(var_ty));
}
