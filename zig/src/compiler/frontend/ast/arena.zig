const std = @import("std");
const ast_node = @import("ast_node.zig");
const typed_arena = @import("../foundation/allocator/typed_arena.zig");

pub const AstExpr = ast_node.AstExpr;
pub const AstStmt = ast_node.AstStmt;
pub const AstDecl = ast_node.AstDecl;
pub const AstTypeRef = ast_node.AstTypeRef;
pub const AstPattern = ast_node.AstPattern;
pub const ExprId = ast_node.ExprId;
pub const StmtId = ast_node.StmtId;
pub const DeclId = ast_node.DeclId;
pub const PatId = ast_node.PatId;
pub const TypeRefId = ast_node.TypeRefId;

pub const AstArena = struct {
    exprs: typed_arena.TypedArena(AstExpr),
    stmts: typed_arena.TypedArena(AstStmt),
    decls: typed_arena.TypedArena(AstDecl),
    type_refs: typed_arena.TypedArena(AstTypeRef),
    patterns: typed_arena.TypedArena(AstPattern),
    param_list: std.ArrayList(ast_node.ParamDef),
    field_list: std.ArrayList(ast_node.FieldDef),
    variant_list: std.ArrayList(ast_node.VariantDef),
    expr_id_list: std.ArrayList(ExprId),
    stmt_id_list: std.ArrayList(StmtId),
    pat_id_list: std.ArrayList(PatId),
    type_ref_id_list: std.ArrayList(TypeRefId),
    match_arm_list: std.ArrayList(AstExpr.MatchArm),
    backing_allocator: std.mem.Allocator,
    arena_ptr: ?*std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) AstArena {
        const aa_ptr = backing.create(std.heap.ArenaAllocator) catch unreachable;
        aa_ptr.* = std.heap.ArenaAllocator.init(backing);
        const aa_alloc = aa_ptr.allocator();
        return .{
            .exprs = typed_arena.TypedArena(AstExpr).init(aa_alloc),
            .stmts = typed_arena.TypedArena(AstStmt).init(aa_alloc),
            .decls = typed_arena.TypedArena(AstDecl).init(aa_alloc),
            .type_refs = typed_arena.TypedArena(AstTypeRef).init(aa_alloc),
            .patterns = typed_arena.TypedArena(AstPattern).init(aa_alloc),
            .param_list = std.ArrayList(ast_node.ParamDef).init(aa_alloc),
            .field_list = std.ArrayList(ast_node.FieldDef).init(aa_alloc),
            .variant_list = std.ArrayList(ast_node.VariantDef).init(aa_alloc),
            .expr_id_list = std.ArrayList(ExprId).init(aa_alloc),
            .stmt_id_list = std.ArrayList(StmtId).init(aa_alloc),
            .pat_id_list = std.ArrayList(PatId).init(aa_alloc),
            .type_ref_id_list = std.ArrayList(TypeRefId).init(aa_alloc),
            .match_arm_list = std.ArrayList(AstExpr.MatchArm).init(aa_alloc),
            .backing_allocator = backing,
            .arena_ptr = aa_ptr,
            .allocator = aa_alloc,
        };
    }

    pub fn deinit(self: *AstArena) void {
        if (self.arena_ptr) |aa| {
            aa.deinit();
            self.backing_allocator.destroy(aa);
            self.arena_ptr = null;
        }
    }

    pub fn addExpr(self: *AstArena, expr: AstExpr) ExprId {
        const idx: u32 = @intCast(self.exprs.items.items.len);
        self.exprs.items.append(expr) catch return ExprId.INVALID;
        return ExprId.new(idx);
    }

    pub fn addStmt(self: *AstArena, stmt: AstStmt) StmtId {
        const idx: u32 = @intCast(self.stmts.items.items.len);
        self.stmts.items.append(stmt) catch return StmtId.INVALID;
        return StmtId.new(idx);
    }

    pub fn addDecl(self: *AstArena, decl: AstDecl) DeclId {
        const idx: u32 = @intCast(self.decls.items.items.len);
        self.decls.items.append(decl) catch return DeclId.INVALID;
        return DeclId.new(idx);
    }

    pub fn addTypeRef(self: *AstArena, type_ref: AstTypeRef) TypeRefId {
        const idx: u32 = @intCast(self.type_refs.items.items.len);
        self.type_refs.items.append(type_ref) catch return TypeRefId.INVALID;
        return TypeRefId.new(idx);
    }

    pub fn addPattern(self: *AstArena, pattern: AstPattern) PatId {
        const idx: u32 = @intCast(self.patterns.items.items.len);
        self.patterns.items.append(pattern) catch return PatId.INVALID;
        return PatId.new(idx);
    }

    pub fn getExpr(self: *const AstArena, id: ExprId) ?AstExpr {
        if (!id.isValid()) return null;
        return self.exprs.get(id.index);
    }

    pub fn getStmt(self: *const AstArena, id: StmtId) ?AstStmt {
        if (!id.isValid()) return null;
        return self.stmts.get(id.index);
    }

    pub fn getDecl(self: *const AstArena, id: DeclId) ?AstDecl {
        if (!id.isValid()) return null;
        return self.decls.get(id.index);
    }

    pub fn getTypeRef(self: *const AstArena, id: TypeRefId) ?AstTypeRef {
        if (!id.isValid()) return null;
        return self.type_refs.get(id.index);
    }

    pub fn getPattern(self: *const AstArena, id: PatId) ?AstPattern {
        if (!id.isValid()) return null;
        return self.patterns.get(id.index);
    }

    pub fn addParam(self: *AstArena, param: ast_node.ParamDef) !*ast_node.ParamDef {
        try self.param_list.append(param);
        return &self.param_list.items[self.param_list.items.len - 1];
    }

    pub fn addField(self: *AstArena, field: ast_node.FieldDef) !*ast_node.FieldDef {
        try self.field_list.append(field);
        return &self.field_list.items[self.field_list.items.len - 1];
    }

    pub fn addVariant(self: *AstArena, variant: ast_node.VariantDef) !*ast_node.VariantDef {
        try self.variant_list.append(variant);
        return &self.variant_list.items[self.variant_list.items.len - 1];
    }

    pub fn addExprId(self: *AstArena, id: ExprId) !*ExprId {
        try self.expr_id_list.append(id);
        return &self.expr_id_list.items[self.expr_id_list.items.len - 1];
    }

    pub fn addStmtId(self: *AstArena, id: StmtId) !*StmtId {
        try self.stmt_id_list.append(id);
        return &self.stmt_id_list.items[self.stmt_id_list.items.len - 1];
    }

    pub fn addMatchArm(self: *AstArena, arm: AstExpr.MatchArm) !*AstExpr.MatchArm {
        try self.match_arm_list.append(arm);
        return &self.match_arm_list.items[self.match_arm_list.items.len - 1];
    }

    pub fn getExprSlice(self: *const AstArena, ids: []const ExprId) []const AstExpr {
        var result = std.ArrayList(AstExpr).init(self.allocator);
        defer result.deinit();
        for (ids) |id| {
            if (self.getExpr(id)) |expr| {
                result.append(expr) catch continue;
            }
        }
        return result.toOwnedSlice() catch &.{};
    }

    pub fn exprCount(self: *const AstArena) u32 {
        return @intCast(self.exprs.items.items.len);
    }

    pub fn stmtCount(self: *const AstArena) u32 {
        return @intCast(self.stmts.items.items.len);
    }

    pub fn declCount(self: *const AstArena) u32 {
        return @intCast(self.decls.items.items.len);
    }
};
