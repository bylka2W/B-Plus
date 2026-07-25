const std = @import("std");
const types_mod = @import("types.zig");
const TypeId = types_mod.TypeId;
const TypeVarId = types_mod.TypeVarId;

pub const UnifyError = error{ OccursCheck, TypeMismatch };

pub const UnificationTable = struct {
    parent: std.ArrayList(TypeVarId),
    rank: std.ArrayList(u32),
    known: std.ArrayList(TypeId),
    var_count: u32,

    pub fn init(alloc: std.mem.Allocator) UnificationTable {
        return .{
            .parent = std.ArrayList(TypeVarId).init(alloc),
            .rank = std.ArrayList(u32).init(alloc),
            .known = std.ArrayList(TypeId).init(alloc),
            .var_count = 0,
        };
    }

    pub fn deinit(self: *UnificationTable) void {
        self.parent.deinit();
        self.rank.deinit();
        self.known.deinit();
    }

    pub fn freshVar(self: *UnificationTable) TypeVarId {
        const id = TypeVarId.new(self.var_count);
        self.var_count += 1;
        self.parent.append(id) catch return TypeVarId.INVALID;
        self.rank.append(0) catch return TypeVarId.INVALID;
        self.known.append(TypeId.INVALID) catch return TypeVarId.INVALID;
        return id;
    }

    fn find(self: *UnificationTable, var_id: TypeVarId) TypeVarId {
        const idx = var_id.index;
        var cur = idx;
        while (true) {
            const p = self.parent.items[cur];
            if (p.index == cur) break;
            cur = p.index;
        }
        var node = idx;
        while (node != cur) {
            const next = self.parent.items[node].index;
            self.parent.items[node] = TypeVarId.new(cur);
            node = next;
        }
        return TypeVarId.new(cur);
    }

    pub fn findKnown(self: *UnificationTable, var_id: TypeVarId) ?TypeId {
        const root = self.find(var_id);
        const ty = self.known.items[root.index];
        if (ty.isValid()) return ty;
        return null;
    }

    pub fn setKnown(self: *UnificationTable, var_id: TypeVarId, ty: TypeId) UnifyError!void {
        const root = self.find(var_id);
        const existing = self.known.items[root.index];
        if (existing.isValid()) {
            if (existing.eql(ty)) return;
            return error.TypeMismatch;
        }
        self.known.items[root.index] = ty;
    }

    pub fn unify(self: *UnificationTable, a: TypeVarId, b: TypeVarId) UnifyError!void {
        const root_a = self.find(a);
        const root_b = self.find(b);
        if (root_a.index == root_b.index) return;

        const known_a = self.known.items[root_a.index];
        const known_b = self.known.items[root_b.index];

        if (known_a.isValid() and known_b.isValid()) {
            if (!known_a.eql(known_b)) return error.TypeMismatch;
            return;
        }

        const rank_a = self.rank.items[root_a.index];
        const rank_b = self.rank.items[root_b.index];

        if (rank_a < rank_b) {
            self.parent.items[root_a.index] = root_b;
            if (known_a.isValid()) {
                self.known.items[root_b.index] = known_a;
            }
        } else if (rank_a > rank_b) {
            self.parent.items[root_b.index] = root_a;
            if (known_b.isValid()) {
                self.known.items[root_a.index] = known_b;
            }
        } else {
            self.parent.items[root_b.index] = root_a;
            self.rank.items[root_a.index] += 1;
            if (known_b.isValid() and !known_a.isValid()) {
                self.known.items[root_a.index] = known_b;
            }
        }
    }

    pub fn resolve(self: *UnificationTable, var_id: TypeVarId) TypeVarId {
        return self.find(var_id);
    }
};

test "UnificationTable: fresh var" {
    var table = UnificationTable.init(std.testing.allocator);
    defer table.deinit();

    const v0 = table.freshVar();
    const v1 = table.freshVar();
    try std.testing.expect(v0.isValid());
    try std.testing.expect(v1.isValid());
    try std.testing.expect(v0.index != v1.index);
    try std.testing.expect(table.findKnown(v0) == null);
}

test "UnificationTable: set and find known" {
    var table = UnificationTable.init(std.testing.allocator);
    defer table.deinit();

    const v0 = table.freshVar();
    const ty = TypeId.new(42);
    try table.setKnown(v0, ty);

    const found = table.findKnown(v0);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.eql(ty));
}

test "UnificationTable: unify two vars" {
    var table = UnificationTable.init(std.testing.allocator);
    defer table.deinit();

    const v0 = table.freshVar();
    const v1 = table.freshVar();
    try table.unify(v0, v1);

    try table.setKnown(v0, TypeId.new(1));
    const found = table.findKnown(v1);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.index == 1);
}

test "UnificationTable: unify with known types" {
    var table = UnificationTable.init(std.testing.allocator);
    defer table.deinit();

    const v0 = table.freshVar();
    const v1 = table.freshVar();
    try table.setKnown(v0, TypeId.new(1));
    try table.setKnown(v1, TypeId.new(1));
    try table.unify(v0, v1);

    const found = table.findKnown(v0);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.index == 1);
}

test "UnificationTable: conflict" {
    var table = UnificationTable.init(std.testing.allocator);
    defer table.deinit();

    const v0 = table.freshVar();
    const v1 = table.freshVar();
    try table.setKnown(v0, TypeId.new(1));
    try table.setKnown(v1, TypeId.new(2));

    const result = table.unify(v0, v1);
    try std.testing.expectError(error.TypeMismatch, result);
}
