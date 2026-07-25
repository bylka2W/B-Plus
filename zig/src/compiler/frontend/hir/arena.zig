const std = @import("std");
const item_mod = @import("item.zig");
const body_mod = @import("body.zig");
const expr_mod = @import("expr.zig");
const stmt_mod = @import("stmt.zig");
const pattern_mod = @import("pattern.zig");
const ty_mod = @import("ty.zig");

pub const HirItem = item_mod.HirItem;
pub const HirBody = body_mod.HirBody;
pub const HirExpr = expr_mod.HirExpr;
pub const HirStmt = stmt_mod.HirStmt;
pub const HirPattern = pattern_mod.HirPattern;
pub const HirTy = ty_mod.HirTy;

pub const HirArena = struct {
    backing_allocator: std.mem.Allocator,
    aa_ptr: ?*std.heap.ArenaAllocator,
    aa_alloc: std.mem.Allocator,

    items: std.ArrayList(HirItem),
    bodies: std.ArrayList(HirBody),
    exprs: std.ArrayList(HirExpr),
    stmts: std.ArrayList(HirStmt),
    patterns: std.ArrayList(HirPattern),
    types: std.ArrayList(HirTy),

    pub const SourceSpan = @import("../source/location/span.zig").SourceSpan;

    pub fn init(backing_allocator: std.mem.Allocator) HirArena {
        const aa_ptr = backing_allocator.create(std.heap.ArenaAllocator) catch unreachable;
        aa_ptr.* = std.heap.ArenaAllocator.init(backing_allocator);
        const aa_alloc = aa_ptr.allocator();
        return .{
            .backing_allocator = backing_allocator,
            .aa_ptr = aa_ptr,
            .aa_alloc = aa_alloc,
            .items = std.ArrayList(HirItem).init(aa_alloc),
            .bodies = std.ArrayList(HirBody).init(aa_alloc),
            .exprs = std.ArrayList(HirExpr).init(aa_alloc),
            .stmts = std.ArrayList(HirStmt).init(aa_alloc),
            .patterns = std.ArrayList(HirPattern).init(aa_alloc),
            .types = std.ArrayList(HirTy).init(aa_alloc),
        };
    }

    pub fn deinit(self: *HirArena) void {
        if (self.aa_ptr) |aa| {
            aa.deinit();
            self.backing_allocator.destroy(aa);
            self.aa_ptr = null;
        }
    }

    pub fn allocator(self: *HirArena) std.mem.Allocator {
        return self.aa_alloc;
    }

    pub fn addItem(self: *HirArena, item: HirItem) ItemId {
        const idx: u32 = @intCast(self.items.items.len);
        self.items.append(item) catch return ItemId.INVALID;
        return ItemId.new(idx);
    }

    pub fn addBody(self: *HirArena, body: HirBody) BodyId {
        const idx: u32 = @intCast(self.bodies.items.len);
        self.bodies.append(body) catch return BodyId.INVALID;
        return BodyId.new(idx);
    }

    pub fn addExpr(self: *HirArena, expr: HirExpr) ExprId {
        const idx: u32 = @intCast(self.exprs.items.len);
        self.exprs.append(expr) catch return ExprId.INVALID;
        return ExprId.new(idx);
    }

    pub fn addStmt(self: *HirArena, stmt: HirStmt) StmtId {
        const idx: u32 = @intCast(self.stmts.items.len);
        self.stmts.append(stmt) catch return StmtId.INVALID;
        return StmtId.new(idx);
    }

    pub fn addPattern(self: *HirArena, pat: HirPattern) PatId {
        const idx: u32 = @intCast(self.patterns.items.len);
        self.patterns.append(pat) catch return PatId.INVALID;
        return PatId.new(idx);
    }

    pub fn addType(self: *HirArena, ty: HirTy) TypeId {
        const idx: u32 = @intCast(self.types.items.len);
        self.types.append(ty) catch return TypeId.INVALID;
        return TypeId.new(idx);
    }

    pub fn getItem(self: *const HirArena, id: ItemId) ?HirItem {
        if (!id.isValid() or id.index >= self.items.items.len) return null;
        return self.items.items[id.index];
    }

    pub fn getBody(self: *const HirArena, id: BodyId) ?HirBody {
        if (!id.isValid() or id.index >= self.bodies.items.len) return null;
        return self.bodies.items[id.index];
    }

    pub fn getExpr(self: *const HirArena, id: ExprId) ?HirExpr {
        if (!id.isValid() or id.index >= self.exprs.items.len) return null;
        return self.exprs.items[id.index];
    }

    pub fn getStmt(self: *const HirArena, id: StmtId) ?HirStmt {
        if (!id.isValid() or id.index >= self.stmts.items.len) return null;
        return self.stmts.items[id.index];
    }

    pub fn getPattern(self: *const HirArena, id: PatId) ?HirPattern {
        if (!id.isValid() or id.index >= self.patterns.items.len) return null;
        return self.patterns.items[id.index];
    }

    pub fn getType(self: *const HirArena, id: TypeId) ?HirTy {
        if (!id.isValid() or id.index >= self.types.items.len) return null;
        return self.types.items[id.index];
    }

    pub fn itemCount(self: *const HirArena) u32 {
        return @intCast(self.items.items.len);
    }

    pub fn bodyCount(self: *const HirArena) u32 {
        return @intCast(self.bodies.items.len);
    }

    pub fn exprCount(self: *const HirArena) u32 {
        return @intCast(self.exprs.items.len);
    }

    pub fn stmtCount(self: *const HirArena) u32 {
        return @intCast(self.stmts.items.len);
    }

    pub fn patternCount(self: *const HirArena) u32 {
        return @intCast(self.patterns.items.len);
    }

    pub fn typeCount(self: *const HirArena) u32 {
        return @intCast(self.types.items.len);
    }

    pub fn allocSlice(self: *HirArena, comptime T: type, items: []const T) ![]const T {
        const alloc = self.allocator();
        const result = try alloc.alloc(T, items.len);
        @memcpy(result, items);
        return result;
    }
};

pub const ExprId = @import("../foundation/ids/ids.zig").ExprId;
pub const StmtId = @import("../foundation/ids/ids.zig").StmtId;
pub const ItemId = @import("../foundation/ids/ids.zig").ItemId;
pub const BodyId = @import("../foundation/ids/ids.zig").BodyId;
pub const PatId = @import("../foundation/ids/ids.zig").PatId;
pub const TypeId = @import("../foundation/ids/ids.zig").TypeId;
