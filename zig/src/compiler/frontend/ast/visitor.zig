const std = @import("std");
const ast_node = @import("ast_node.zig");
const arena_mod = @import("arena.zig");

pub const ExprId = ast_node.ExprId;
pub const StmtId = ast_node.StmtId;
pub const DeclId = ast_node.DeclId;
pub const PatId = ast_node.PatId;
pub const TypeRefId = ast_node.TypeRefId;
pub const AstArena = arena_mod.AstArena;

pub fn AstVisitor(comptime Context: type) type {
    return struct {
        ctx: Context,
        arena: *AstArena,

        const Self = @This();

        pub fn init(arena: *AstArena, ctx: Context) Self {
            return .{ .ctx = ctx, .arena = arena };
        }

        pub fn visitExpr(self: *Self, id: ExprId) void {
            const expr = self.arena.getExpr(id) orelse return;
            switch (expr) {
                .literal => |e| self.onLiteral(e),
                .identifier => |e| self.onIdentifier(e),
                .binary => |e| {
                    self.onBinary(e);
                    self.visitExpr(e.left);
                    self.visitExpr(e.right);
                },
                .unary => |e| {
                    self.onUnary(e);
                    self.visitExpr(e.operand);
                },
                .call => |e| {
                    self.onCall(e);
                    self.visitExpr(e.callee);
                    for (e.args) |arg| self.visitExpr(arg);
                },
                .member => |e| {
                    self.onMember(e);
                    self.visitExpr(e.object);
                },
                .index => |e| {
                    self.onIndex(e);
                    self.visitExpr(e.object);
                    self.visitExpr(e.index);
                },
                .paren => |e| {
                    self.onParen(e);
                    self.visitExpr(e.inner);
                },
                .if_expr => |e| {
                    self.onIfExpr(e);
                    self.visitExpr(e.condition);
                    self.visitExpr(e.then_block);
                    if (e.else_branch) |eb| self.visitExpr(eb);
                },
                .while_expr => |e| {
                    self.onWhileExpr(e);
                    self.visitExpr(e.condition);
                    self.visitExpr(e.body);
                },
                .for_expr => |e| {
                    self.onForExpr(e);
                    self.visitExpr(e.iterable);
                    self.visitExpr(e.body);
                },
                .loop_expr => |e| {
                    self.onLoopExpr(e);
                    self.visitExpr(e.body);
                },
                .block => |e| {
                    self.onBlockExpr(e);
                    for (e.stmts) |sid| self.visitStmt(sid);
                },
                .assign => |e| {
                    self.onAssignExpr(e);
                    self.visitExpr(e.target);
                    self.visitExpr(e.value);
                },
                .return_expr => |e| {
                    self.onReturnExpr(e);
                    if (e.value) |v| self.visitExpr(v);
                },
                .break_expr => |e| self.onBreakExpr(e),
                .continue_expr => |e| self.onContinueExpr(e),
                .closure => |e| {
                    self.onClosureExpr(e);
                    self.visitExpr(e.body);
                },
                .match_expr => |e| {
                    self.onMatchExpr(e);
                    self.visitExpr(e.scrutinee);
                    for (e.arms) |arm| {
                        self.visitPat(arm.pattern);
                        if (arm.guard) |g| self.visitExpr(g);
                        self.visitExpr(arm.body);
                    }
                },
                .range => |e| {
                    self.onRangeExpr(e);
                    if (e.start) |s| self.visitExpr(s);
                    if (e.end) |en| self.visitExpr(en);
                },
                .try_expr => |e| {
                    self.onTryExpr(e);
                    self.visitExpr(e.operand);
                },
                .type_cast => |e| {
                    self.onTypeCastExpr(e);
                    self.visitExpr(e.operand);
                    self.visitTypeRef(e.target_type);
                },
                .missing => |e| self.onMissingExpr(e),
            }
        }

        pub fn visitStmt(self: *Self, id: StmtId) void {
            const stmt = self.arena.getStmt(id) orelse return;
            switch (stmt) {
                .let => |s| {
                    self.onLetStmt(s);
                    self.visitPat(s.pattern);
                    if (s.type_annotation) |t| self.visitTypeRef(t);
                    if (s.init) |i| self.visitExpr(i);
                },
                .@"var" => |s| {
                    self.onVarStmt(s);
                    self.visitPat(s.pattern);
                    if (s.type_annotation) |t| self.visitTypeRef(t);
                    if (s.init) |i| self.visitExpr(i);
                },
                .const_stmt => |s| {
                    self.onConstStmt(s);
                    self.visitPat(s.pattern);
                    if (s.type_annotation) |t| self.visitTypeRef(t);
                    self.visitExpr(s.init);
                },
                .expr_stmt => |s| {
                    self.onExprStmt(s);
                    self.visitExpr(s.expr);
                },
                .block => |s| {
                    self.onBlockStmt(s);
                    for (s.stmts) |sid| self.visitStmt(sid);
                },
                .if_stmt => |s| {
                    self.onIfStmt(s);
                    self.visitExpr(s.condition);
                    self.visitStmt(s.then_block);
                    if (s.else_branch) |eb| self.visitStmt(eb);
                },
                .while_stmt => |s| {
                    self.onWhileStmt(s);
                    self.visitExpr(s.condition);
                    self.visitStmt(s.body);
                },
                .for_stmt => |s| {
                    self.onForStmt(s);
                    self.visitExpr(s.iterable);
                    self.visitStmt(s.body);
                },
                .loop_stmt => |s| {
                    self.onLoopStmt(s);
                    self.visitStmt(s.body);
                },
                .return_stmt => |s| {
                    self.onReturnStmt(s);
                    if (s.value) |v| self.visitExpr(v);
                },
                .break_stmt => |s| self.onBreakStmt(s),
                .continue_stmt => |s| self.onContinueStmt(s),
                .defer_stmt => |s| {
                    self.onDeferStmt(s);
                    self.visitStmt(s.body);
                },
                .errdefer_stmt => |s| {
                    self.onErrdeferStmt(s);
                    self.visitStmt(s.body);
                },
                .missing => |s| self.onMissingStmt(s),
            }
        }

        pub fn visitDecl(self: *Self, id: DeclId) void {
            const decl = self.arena.getDecl(id) orelse return;
            switch (decl) {
                .fn_decl => |d| {
                    self.onFnDecl(d);
                    if (d.body) |b| self.visitStmt(b);
                },
                .struct_decl => |d| self.onStructDecl(d),
                .enum_decl => |d| self.onEnumDecl(d),
                .trait_decl => |d| self.onTraitDecl(d),
                .impl_decl => |d| self.onImplDecl(d),
                .type_alias => |d| self.onTypeAliasDecl(d),
                .import => |d| self.onImportDecl(d),
                .module => |d| self.onModuleDecl(d),
                .extern_fn => |d| self.onExternFnDecl(d),
                .missing => |d| self.onMissingDecl(d),
            }
        }

        pub fn visitPat(self: *Self, id: PatId) void {
            const pat = self.arena.getPattern(id) orelse return;
            switch (pat) {
                .identifier => |p| self.onIdentifierPat(p),
                .wildcard => |p| self.onWildcardPat(p),
                .literal => |p| {
                    self.onLiteralPat(p);
                    self.visitExpr(p.value);
                },
                .tuple => |p| {
                    self.onTuplePat(p);
                    for (p.elements) |eid| self.visitPat(eid);
                },
                .path => |p| self.onPathPat(p),
                .missing => |p| self.onMissingPat(p),
            }
        }

        pub fn visitTypeRef(self: *Self, id: TypeRefId) void {
            const tr = self.arena.getTypeRef(id) orelse return;
            switch (tr) {
                .named => |t| self.onNamedType(t),
                .pointer => |t| {
                    self.onPointerType(t);
                    self.visitTypeRef(t.pointee);
                },
                .array => |t| {
                    self.onArrayType(t);
                    self.visitTypeRef(t.element);
                    if (t.length) |l| self.visitExpr(l);
                },
                .slice => |t| {
                    self.onSliceType(t);
                    self.visitTypeRef(t.element);
                },
                .tuple => |t| {
                    self.onTupleType(t);
                    for (t.elements) |eid| self.visitTypeRef(eid);
                },
                .fn_type => |t| {
                    self.onFnType(t);
                    self.visitTypeRef(t.return_type);
                },
                .optional => |t| {
                    self.onOptionalType(t);
                    self.visitTypeRef(t.inner);
                },
                .missing => |t| self.onMissingType(t),
            }
        }

        fn onLiteral(self: *Self, e: ast_node.AstExpr.LiteralExpr) void { _ = self; _ = e; }
        fn onIdentifier(self: *Self, e: ast_node.AstExpr.IdentifierExpr) void { _ = self; _ = e; }
        fn onBinary(self: *Self, e: ast_node.AstExpr.BinaryExpr) void { _ = self; _ = e; }
        fn onUnary(self: *Self, e: ast_node.AstExpr.UnaryExpr) void { _ = self; _ = e; }
        fn onCall(self: *Self, e: ast_node.AstExpr.CallExpr) void { _ = self; _ = e; }
        fn onMember(self: *Self, e: ast_node.AstExpr.MemberExpr) void { _ = self; _ = e; }
        fn onIndex(self: *Self, e: ast_node.AstExpr.IndexExpr) void { _ = self; _ = e; }
        fn onParen(self: *Self, e: ast_node.AstExpr.ParenExpr) void { _ = self; _ = e; }
        fn onIfExpr(self: *Self, e: ast_node.AstExpr.IfExpr) void { _ = self; _ = e; }
        fn onWhileExpr(self: *Self, e: ast_node.AstExpr.WhileExpr) void { _ = self; _ = e; }
        fn onForExpr(self: *Self, e: ast_node.AstExpr.ForExpr) void { _ = self; _ = e; }
        fn onLoopExpr(self: *Self, e: ast_node.AstExpr.LoopExpr) void { _ = self; _ = e; }
        fn onBlockExpr(self: *Self, e: ast_node.AstExpr.BlockExpr) void { _ = self; _ = e; }
        fn onAssignExpr(self: *Self, e: ast_node.AstExpr.AssignExpr) void { _ = self; _ = e; }
        fn onReturnExpr(self: *Self, e: ast_node.AstExpr.ReturnExpr) void { _ = self; _ = e; }
        fn onBreakExpr(self: *Self, e: ast_node.AstExpr.BreakExpr) void { _ = self; _ = e; }
        fn onContinueExpr(self: *Self, e: ast_node.AstExpr.ContinueExpr) void { _ = self; _ = e; }
        fn onClosureExpr(self: *Self, e: ast_node.AstExpr.ClosureExpr) void { _ = self; _ = e; }
        fn onMatchExpr(self: *Self, e: ast_node.AstExpr.MatchExpr) void { _ = self; _ = e; }
        fn onRangeExpr(self: *Self, e: ast_node.AstExpr.RangeExpr) void { _ = self; _ = e; }
        fn onTryExpr(self: *Self, e: ast_node.AstExpr.TryExpr) void { _ = self; _ = e; }
        fn onTypeCastExpr(self: *Self, e: ast_node.AstExpr.TypeCastExpr) void { _ = self; _ = e; }
        fn onMissingExpr(self: *Self, e: ast_node.AstExpr.MissingExpr) void { _ = self; _ = e; }

        fn onLetStmt(self: *Self, s: ast_node.AstStmt.LetStmt) void { _ = self; _ = s; }
        fn onVarStmt(self: *Self, s: ast_node.AstStmt.VarStmt) void { _ = self; _ = s; }
        fn onConstStmt(self: *Self, s: ast_node.AstStmt.ConstStmt) void { _ = self; _ = s; }
        fn onExprStmt(self: *Self, s: ast_node.AstStmt.ExprStmt) void { _ = self; _ = s; }
        fn onBlockStmt(self: *Self, s: ast_node.AstStmt.BlockStmt) void { _ = self; _ = s; }
        fn onIfStmt(self: *Self, s: ast_node.AstStmt.IfStmt) void { _ = self; _ = s; }
        fn onWhileStmt(self: *Self, s: ast_node.AstStmt.WhileStmt) void { _ = self; _ = s; }
        fn onForStmt(self: *Self, s: ast_node.AstStmt.ForStmt) void { _ = self; _ = s; }
        fn onLoopStmt(self: *Self, s: ast_node.AstStmt.LoopStmt) void { _ = self; _ = s; }
        fn onReturnStmt(self: *Self, s: ast_node.AstStmt.ReturnStmt) void { _ = self; _ = s; }
        fn onBreakStmt(self: *Self, s: ast_node.AstStmt.BreakStmt) void { _ = self; _ = s; }
        fn onContinueStmt(self: *Self, s: ast_node.AstStmt.ContinueStmt) void { _ = self; _ = s; }
        fn onDeferStmt(self: *Self, s: ast_node.AstStmt.DeferStmt) void { _ = self; _ = s; }
        fn onErrdeferStmt(self: *Self, s: ast_node.AstStmt.ErrdeferStmt) void { _ = self; _ = s; }
        fn onMissingStmt(self: *Self, s: ast_node.AstStmt.MissingStmt) void { _ = self; _ = s; }

        fn onFnDecl(self: *Self, d: ast_node.AstDecl.FnDecl) void { _ = self; _ = d; }
        fn onStructDecl(self: *Self, d: ast_node.AstDecl.StructDecl) void { _ = self; _ = d; }
        fn onEnumDecl(self: *Self, d: ast_node.AstDecl.EnumDecl) void { _ = self; _ = d; }
        fn onTraitDecl(self: *Self, d: ast_node.AstDecl.TraitDecl) void { _ = self; _ = d; }
        fn onImplDecl(self: *Self, d: ast_node.AstDecl.ImplDecl) void { _ = self; _ = d; }
        fn onTypeAliasDecl(self: *Self, d: ast_node.AstDecl.TypeAliasDecl) void { _ = self; _ = d; }
        fn onImportDecl(self: *Self, d: ast_node.AstDecl.ImportDecl) void { _ = self; _ = d; }
        fn onModuleDecl(self: *Self, d: ast_node.AstDecl.ModuleDecl) void { _ = self; _ = d; }
        fn onExternFnDecl(self: *Self, d: ast_node.AstDecl.ExternFnDecl) void { _ = self; _ = d; }
        fn onMissingDecl(self: *Self, d: ast_node.AstDecl.MissingDecl) void { _ = self; _ = d; }

        fn onIdentifierPat(self: *Self, p: ast_node.AstPattern.IdentifierPattern) void { _ = self; _ = p; }
        fn onWildcardPat(self: *Self, p: ast_node.AstPattern.WildcardPattern) void { _ = self; _ = p; }
        fn onLiteralPat(self: *Self, p: ast_node.AstPattern.LiteralPattern) void { _ = self; _ = p; }
        fn onTuplePat(self: *Self, p: ast_node.AstPattern.TuplePattern) void { _ = self; _ = p; }
        fn onPathPat(self: *Self, p: ast_node.AstPattern.PathPattern) void { _ = self; _ = p; }
        fn onMissingPat(self: *Self, p: ast_node.AstPattern.MissingPattern) void { _ = self; _ = p; }

        fn onNamedType(self: *Self, t: ast_node.AstTypeRef.NamedType) void { _ = self; _ = t; }
        fn onPointerType(self: *Self, t: ast_node.AstTypeRef.PointerType) void { _ = self; _ = t; }
        fn onArrayType(self: *Self, t: ast_node.AstTypeRef.ArrayType) void { _ = self; _ = t; }
        fn onSliceType(self: *Self, t: ast_node.AstTypeRef.SliceType) void { _ = self; _ = t; }
        fn onTupleType(self: *Self, t: ast_node.AstTypeRef.TupleType) void { _ = self; _ = t; }
        fn onFnType(self: *Self, t: ast_node.AstTypeRef.FnType) void { _ = self; _ = t; }
        fn onOptionalType(self: *Self, t: ast_node.AstTypeRef.OptionalType) void { _ = self; _ = t; }
        fn onMissingType(self: *Self, t: ast_node.AstTypeRef.MissingType) void { _ = self; _ = t; }
    };
}
