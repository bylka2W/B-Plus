const std = @import("std");
const types_mod = @import("types.zig");
const TypeId = types_mod.TypeId;

pub const ConstraintSet = struct {
    constraints: std.ArrayList(Constraint),
    arena_alloc: std.mem.Allocator,

    pub const Constraint = struct {
        kind: ConstraintKind,
        span: u32,
    };

    pub const ConstraintKind = union(enum) {
        eq: EqData,
        subtype: EqData,
        class: ClassData,
        projection: ProjectionData,
        lifetime: LifetimeData,
    };

    pub const EqData = struct {
        left: TypeId,
        right: TypeId,
    };

    pub const ClassData = struct {
        ty: TypeId,
        kind: ClassKind,
    };

    pub const ProjectionData = struct {
        self_ty: TypeId,
        trait_def: u32,
        item_name: u32,
        result_ty: TypeId,
    };

    pub const LifetimeData = struct {
        region: u32,
        kind: RegionKind,
    };

    pub const ClassKind = enum {
        numeric,
        integral,
        float_type,
        signed,
        ordered,
        printable,
        copy,
        clone,
    };

    pub const RegionKind = enum {
        @"fn",
        block,
        early_bound,
    };

    pub fn init(alloc: std.mem.Allocator) ConstraintSet {
        return .{
            .constraints = std.ArrayList(Constraint).init(alloc),
            .arena_alloc = alloc,
        };
    }

    pub fn deinit(self: *ConstraintSet) void {
        self.constraints.deinit();
    }

    pub fn addEq(self: *ConstraintSet, left: TypeId, right: TypeId, span: u32) !void {
        self.constraints.append(.{ .kind = .{ .eq = .{ .left = left, .right = right } }, .span = span }) catch return error.OutOfMemory;
    }

    pub fn addSubtype(self: *ConstraintSet, left: TypeId, right: TypeId, span: u32) !void {
        self.constraints.append(.{ .kind = .{ .subtype = .{ .left = left, .right = right } }, .span = span }) catch return error.OutOfMemory;
    }

    pub fn addClass(self: *ConstraintSet, ty: TypeId, kind: ClassKind, span: u32) !void {
        self.constraints.append(.{ .kind = .{ .class = .{ .ty = ty, .kind = kind } }, .span = span }) catch return error.OutOfMemory;
    }

    pub fn addProjection(self: *ConstraintSet, self_ty: TypeId, trait_def: u32, item_name: u32, result_ty: TypeId, span: u32) !void {
        self.constraints.append(.{ .kind = .{ .projection = .{ .self_ty = self_ty, .trait_def = trait_def, .item_name = item_name, .result_ty = result_ty } }, .span = span }) catch return error.OutOfMemory;
    }

    pub fn count(self: *const ConstraintSet) u32 {
        return @intCast(self.constraints.items.len);
    }

    pub fn get(self: *const ConstraintSet, index: u32) ?Constraint {
        if (index >= self.constraints.items.len) return null;
        return self.constraints.items[index];
    }
};

test "ConstraintSet: add and query" {
    var cs = ConstraintSet.init(std.testing.allocator);
    defer cs.deinit();

    try cs.addEq(TypeId.new(0), TypeId.new(1), 10);
    try cs.addSubtype(TypeId.new(2), TypeId.new(3), 20);
    try cs.addClass(TypeId.new(0), .numeric, 30);

    try std.testing.expect(cs.count() == 3);
    const c0 = cs.get(0).?;
    try std.testing.expect(c0.kind == .eq);
    try std.testing.expect(c0.span == 10);
}
