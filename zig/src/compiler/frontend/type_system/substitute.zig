const std = @import("std");
const types_mod = @import("types.zig");
const TypeData = types_mod.TypeData;
const TypeId = types_mod.TypeId;
const TypeVarId = types_mod.TypeVarId;
const arena_mod = @import("arena.zig");
const TypeArena = arena_mod.TypeArena;

pub const Substitution = struct {
    arena: *TypeArena,
    mapping: std.AutoHashMap(TypeVarId, TypeId),

    pub fn init(arena: *TypeArena) Substitution {
        return .{
            .arena = arena,
            .mapping = std.AutoHashMap(TypeVarId, TypeId).init(arena.allocator()),
        };
    }

    pub fn insert(self: *Substitution, var_id: TypeVarId, replacement: TypeId) !void {
        try self.mapping.put(var_id, replacement);
    }

    pub fn lookup(self: *const Substitution, var_id: TypeVarId) ?TypeId {
        return self.mapping.get(var_id);
    }

    pub fn apply(self: *const Substitution, ty: TypeId) TypeId {
        const data = self.arena.get(ty) orelse return ty;
        return switch (data) {
            .infer_var => |iv| {
                if (self.mapping.get(iv.var_id)) |replacement| {
                    return self.apply(replacement);
                }
                return ty;
            },
            .pointer => |p| {
                const new_ptee = self.apply(p.pointee);
                if (new_ptee.eql(p.pointee)) return ty;
                return self.arena.pointer(p.mutable, new_ptee);
            },
            .slice => |s| {
                const new_elem = self.apply(s.element);
                if (new_elem.eql(s.element)) return ty;
                return self.arena.slice(new_elem);
            },
            .array => |a| {
                const new_elem = self.apply(a.element);
                if (new_elem.eql(a.element)) return ty;
                return self.arena.array(new_elem, a.length);
            },
            .tuple => |t| {
                var changed = false;
                var new_elems = std.ArrayList(TypeId).init(self.arena.allocator());
                for (t.elements) |elem| {
                    const new_e = self.apply(elem);
                    if (!new_e.eql(elem)) changed = true;
                    new_elems.append(new_e) catch return ty;
                }
                if (!changed) return ty;
                return self.arena.tuple(new_elems.items);
            },
            .fn_ptr => |f| {
                var changed = false;
                var new_params = std.ArrayList(TypeId).init(self.arena.allocator());
                for (f.params) |p| {
                    const new_p = self.apply(p);
                    if (!new_p.eql(p)) changed = true;
                    new_params.append(new_p) catch return ty;
                }
                const new_ret = self.apply(f.ret);
                if (!new_ret.eql(f.ret)) changed = true;
                if (!changed) return ty;
                return self.arena.fnPtr(new_params.items, new_ret, f.is_variadic);
            },
            .reference => |r| {
                const new_ref = self.apply(r.referent);
                if (new_ref.eql(r.referent)) return ty;
                return self.arena.reference(r.mutable, new_ref);
            },
            .optional => |o| {
                const new_inner = self.apply(o.inner);
                if (new_inner.eql(o.inner)) return ty;
                return self.arena.optional(new_inner);
            },
            .error_union => |eu| {
                const new_ok = self.apply(eu.ok);
                const new_err = self.apply(eu.err);
                if (new_ok.eql(eu.ok) and new_err.eql(eu.err)) return ty;
                return self.arena.errorUnion(new_ok, new_err);
            },
            else => ty,
        };
    }
};

test "Substitution: apply to infer var" {
    var ta = TypeArena.init(std.testing.allocator);
    defer ta.deinit();

    var sub = Substitution.init(&ta);
    const v = TypeVarId.new(0);
    const i32_ty = ta.builtin(.i32_type);

    sub.insert(v, i32_ty) catch unreachable;

    const var_ty = ta.inferVar(v);
    const result = sub.apply(var_ty);
    try std.testing.expect(result.eql(i32_ty));
}

test "Substitution: apply to compound type" {
    var ta = TypeArena.init(std.testing.allocator);
    defer ta.deinit();

    var sub = Substitution.init(&ta);
    const v = TypeVarId.new(0);
    const i32_ty = ta.builtin(.i32_type);

    sub.insert(v, i32_ty) catch unreachable;

    const opt_var = ta.inferVar(v);
    const ref_opt = ta.reference(.@"const", opt_var);

    const result = sub.apply(ref_opt);
    const data = ta.get(result).?.reference;
    try std.testing.expect(data.referent.eql(i32_ty));
    try std.testing.expect(data.mutable == .@"const");
}
