const std = @import("std");
const types_mod = @import("types.zig");
const TypeData = types_mod.TypeData;
const TypeId = types_mod.TypeId;
const TypeVarId = types_mod.TypeVarId;

pub const TypeArena = struct {
    backing: std.mem.Allocator,
    aa_ptr: ?*std.heap.ArenaAllocator,
    types: std.ArrayList(TypeData),
    interning: std.AutoHashMap(InternKey, TypeId),

    const InternKey = struct {
        tag: @TypeOf(@as(TypeData, undefined)),
        index: u32,
    };

    pub fn init(backing: std.mem.Allocator) TypeArena {
        const aa_ptr = backing.create(std.heap.ArenaAllocator) catch unreachable;
        aa_ptr.* = std.heap.ArenaAllocator.init(backing);
        const aa_alloc = aa_ptr.allocator();
        return .{
            .backing = backing,
            .aa_ptr = aa_ptr,
            .types = std.ArrayList(TypeData).init(aa_alloc),
            .interning = std.AutoHashMap(InternKey, TypeId).init(aa_alloc),
        };
    }

    pub fn deinit(self: *TypeArena) void {
        if (self.aa_ptr) |aa| {
            aa.deinit();
            self.backing.destroy(aa);
            self.aa_ptr = null;
        }
    }

    pub fn allocator(self: *TypeArena) std.mem.Allocator {
        return self.aa_ptr.?.allocator();
    }

    pub fn intern(self: *TypeArena, td: TypeData) TypeId {
        const idx: u32 = @intCast(self.types.items.len);
        self.types.append(td) catch return TypeId.INVALID;
        return TypeId.new(idx);
    }

    pub fn internSlice(self: *TypeArena, comptime T: type, items: []const T) ![]const TypeId {
        const alloc = self.allocator();
        var result = std.ArrayList(TypeId).init(alloc);
        for (items) |item| {
            result.append(self.intern(item)) catch return error.OutOfMemory;
        }
        return result.toOwnedSlice() catch return error.OutOfMemory;
    }

    pub fn get(self: *const TypeArena, id: TypeId) ?TypeData {
        if (!id.isValid() or id.index >= self.types.items.len) return null;
        return self.types.items[id.index];
    }

    pub fn count(self: *const TypeArena) u32 {
        return @intCast(self.types.items.len);
    }

    pub fn builtin(self: *TypeArena, kind: types_mod.BuiltinKind) TypeId {
        return self.intern(.{ .builtin = kind });
    }

    pub fn pointer(self: *TypeArena, mutable: types_mod.Mutability, pointee: TypeId) TypeId {
        return self.intern(.{ .pointer = .{ .mutable = mutable, .pointee = pointee } });
    }

    pub fn slice(self: *TypeArena, element: TypeId) TypeId {
        return self.intern(.{ .slice = .{ .element = element } });
    }

    pub fn array(self: *TypeArena, element: TypeId, length: u64) TypeId {
        return self.intern(.{ .array = .{ .element = element, .length = length } });
    }

    pub fn tuple(self: *TypeArena, elements: []const TypeId) TypeId {
        const owned = self.allocator().alloc(TypeId, elements.len) catch return TypeId.INVALID;
        @memcpy(owned, elements);
        return self.intern(.{ .tuple = .{ .elements = owned } });
    }

    pub fn fnPtr(self: *TypeArena, params: []const TypeId, ret: TypeId, variadic: bool) TypeId {
        const owned = self.allocator().alloc(TypeId, params.len) catch return TypeId.INVALID;
        @memcpy(owned, params);
        return self.intern(.{ .fn_ptr = .{ .params = owned, .ret = ret, .is_variadic = variadic } });
    }

    pub fn reference(self: *TypeArena, mutable: types_mod.Mutability, referent: TypeId) TypeId {
        return self.intern(.{ .reference = .{ .mutable = mutable, .referent = referent } });
    }

    pub fn optional(self: *TypeArena, inner: TypeId) TypeId {
        return self.intern(.{ .optional = .{ .inner = inner } });
    }

    pub fn errorUnion(self: *TypeArena, ok: TypeId, err: TypeId) TypeId {
        return self.intern(.{ .error_union = .{ .ok = ok, .err = err } });
    }

    pub fn adt(self: *TypeArena, def_id: ids.DefId, args: []const TypeId) TypeId {
        const owned = self.allocator().alloc(TypeId, args.len) catch return TypeId.INVALID;
        @memcpy(owned, args);
        return self.intern(.{ .adt = .{ .def_id = def_id, .args = owned } });
    }

    pub fn typeParam(self: *TypeArena, index: u32, name: ids.SymbolId) TypeId {
        return self.intern(.{ .type_param = .{ .index = index, .name = name } });
    }

    pub fn inferVar(self: *TypeArena, var_id: TypeVarId) TypeId {
        return self.intern(.{ .infer_var = .{ .var_id = var_id } });
    }

    pub fn resolvedVar(self: *TypeArena, target: TypeId) TypeId {
        return self.intern(.{ .resolved_var = target });
    }

    pub fn never(self: *TypeArena) TypeId {
        return self.intern(.{ .never = {} });
    }

    pub fn unit(self: *TypeArena) TypeId {
        return self.intern(.{ .unit = {} });
    }

    pub fn errorType(self: *TypeArena) TypeId {
        return self.intern(.{ .error_type = {} });
    }

    pub fn voidType(self: *TypeArena) TypeId {
        return self.builtin(.void_type);
    }

    pub fn format(self: *const TypeArena, id: TypeId, writer: anytype) !void {
        if (self.get(id)) |td| {
            try td.format("", .{}, writer);
        } else {
            try writer.print("Type({d})", .{id.index});
        }
    }
};

const ids = @import("../foundation/ids/ids.zig");

test "TypeArena: create primitives" {
    var arena = TypeArena.init(std.testing.allocator);
    defer arena.deinit();

    const i32_ty = arena.builtin(.i32_type);
    const bool_ty = arena.builtin(.bool_type);
    const void_ty = arena.voidType();

    try std.testing.expect(i32_ty.isValid());
    try std.testing.expect(bool_ty.isValid());
    try std.testing.expect(void_ty.isValid());
    try std.testing.expect(i32_ty.index != bool_ty.index);
    try std.testing.expect(arena.count() == 3);

    const got = arena.get(i32_ty);
    try std.testing.expect(got != null);
    try std.testing.expect(got.?.builtin == .i32_type);
}

test "TypeArena: compound types" {
    var arena = TypeArena.init(std.testing.allocator);
    defer arena.deinit();

    const i32_ty = arena.builtin(.i32_type);
    const bool_ty = arena.builtin(.bool_type);

    const ref_ty = arena.reference(.@"const", i32_ty);
    try std.testing.expect(ref_ty.isValid());
    const ref_data = arena.get(ref_ty).?.reference;
    try std.testing.expect(ref_data.mutable == .@"const");
    try std.testing.expect(ref_data.referent.eql(i32_ty));

    const opt_ty = arena.optional(bool_ty);
    try std.testing.expect(opt_ty.isValid());
    try std.testing.expect(arena.get(opt_ty).?.optional.inner.eql(bool_ty));

    const slice_ty = arena.slice(i32_ty);
    try std.testing.expect(slice_ty.isValid());

    const arr_ty = arena.array(i32_ty, 10);
    try std.testing.expect(arr_ty.isValid());
    try std.testing.expect(arena.get(arr_ty).?.array.length == 10);

    const params = [_]TypeId{ i32_ty, bool_ty };
    const fn_ty = arena.fnPtr(&params, arena.builtin(.void_type), false);
    try std.testing.expect(fn_ty.isValid());

    const tup_ty = arena.tuple(&params);
    try std.testing.expect(tup_ty.isValid());
}

test "TypeArena: never and error" {
    var arena = TypeArena.init(std.testing.allocator);
    defer arena.deinit();

    const never_ty = arena.never();
    const err_ty = arena.errorType();
    try std.testing.expect(never_ty.isValid());
    try std.testing.expect(err_ty.isValid());
    try std.testing.expect(arena.get(never_ty).? == .never);
    try std.testing.expect(arena.get(err_ty).? == .error_type);
}
