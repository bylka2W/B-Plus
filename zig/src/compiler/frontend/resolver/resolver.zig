const std = @import("std");
const def_mod = @import("def.zig");
const scope_mod = @import("scope.zig");
const ast_node = @import("../ast/ast_node.zig");
const arena_mod = @import("../ast/arena.zig");
const ids = @import("../foundation/ids/ids.zig");

pub const DefId = def_mod.DefId;
pub const SymbolId = ids.SymbolId;
pub const DefKind = def_mod.DefKind;
pub const Def = def_mod.Def;
pub const DefTable = def_mod.DefTable;
pub const ScopeChain = scope_mod.ScopeChain;
pub const ScopeKind = scope_mod.ScopeKind;

pub const AstArena = arena_mod.AstArena;
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
pub const ParamDef = ast_node.ParamDef;

pub const ResolvedRef = struct {
    expr_id: ExprId,
    def_id: DefId,
};

pub const Resolver = struct {
    defs: DefTable,
    scopes: ScopeChain,
    current_scope: u32,
    global_scope: u32,
    current_owner: DefId,
    refs: std.ArrayList(ResolvedRef),

    pub fn init(allocator: std.mem.Allocator) Resolver {
        var scopes = ScopeChain.init(allocator);
        const global_scope = scopes.pushScope(.module, null, DefId.INVALID);
        return .{
            .defs = DefTable.init(allocator),
            .scopes = scopes,
            .current_scope = global_scope,
            .global_scope = global_scope,
            .current_owner = DefId.INVALID,
            .refs = std.ArrayList(ResolvedRef).init(allocator),
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.defs.deinit();
        self.scopes.deinit();
        self.refs.deinit();
    }

    pub fn resolve(self: *Resolver, arena: *AstArena) void {
        self.current_scope = self.global_scope;
        const count = arena.declCount();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (arena.getDecl(DeclId.new(i))) |decl| {
                self.resolveDecl(arena, decl);
            }
        }
    }

    fn addDef(self: *Resolver, kind: DefKind, name: SymbolId, owner: DefId) DefId {
        const def = Def{
            .id = DefId.INVALID,
            .kind = kind,
            .name = name,
            .owner = owner,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        };
        const id = self.defs.addDef(def);
        if (self.defs.getDef(id)) |d| {
            d.id = id;
        }
        self.defs.addName(name, id);
        self.scopes.defineInScope(self.current_scope, name, id);
        return id;
    }

    pub fn resolveDecl(self: *Resolver, arena: *AstArena, decl: AstDecl) void {
        switch (decl) {
            .fn_decl => |f| self.resolveFnDecl(arena, f),
            .struct_decl => |s| self.resolveStructDecl(s),
            .enum_decl => |e| self.resolveEnumDecl(e),
            .trait_decl => |t| self.resolveTraitDecl(arena, t),
            .impl_decl => |i| self.resolveImplDecl(arena, i),
            .type_alias => |t| self.resolveTypeAlias(t),
            .import => |i| self.resolveImport(i),
            .extern_fn => |e| self.resolveExternFn(e),
            .module, .missing => {},
        }
    }

    fn resolveFnDecl(self: *Resolver, arena: *AstArena, f: AstDecl.FnDecl) void {
        if (!f.name.isValid()) return;

        const def_id = self.addDef(.function, f.name, DefId.INVALID);

        if (f.body) |body_id| {
            const fn_scope = self.scopes.pushScope(.function, self.current_scope, def_id);

            if (self.defs.getDef(def_id)) |d| {
                d.owner = def_id;
            }

            const prev_scope = self.current_scope;
            const prev_owner = self.current_owner;
            self.current_scope = fn_scope;
            self.current_owner = def_id;

            for (f.params) |param| {
                self.resolveParam(param, def_id);
            }

            self.resolveStmt(arena, body_id);

            self.current_scope = prev_scope;
            self.current_owner = prev_owner;
        }
    }

    fn resolveParam(self: *Resolver, param: ParamDef, owner: DefId) void {
        if (!param.name.isValid()) return;
        _ = self.addDef(.parameter, param.name, owner);
    }

    fn resolveStructDecl(self: *Resolver, s: AstDecl.StructDecl) void {
        if (!s.name.isValid()) return;

        const def_id = self.addDef(.struct_type, s.name, DefId.INVALID);
        if (self.defs.getDef(def_id)) |d| {
            d.owner = def_id;
        }

        for (s.fields) |field| {
            if (field.name.isValid()) {
                _ = self.addDef(.field, field.name, def_id);
            }
        }
    }

    fn resolveEnumDecl(self: *Resolver, e: AstDecl.EnumDecl) void {
        if (!e.name.isValid()) return;

        const def_id = self.addDef(.enum_type, e.name, DefId.INVALID);
        if (self.defs.getDef(def_id)) |d| {
            d.owner = def_id;
        }

        for (e.variants) |variant| {
            if (variant.name.isValid()) {
                _ = self.addDef(.enum_variant, variant.name, def_id);
            }
        }
    }

    fn resolveTraitDecl(self: *Resolver, arena: *AstArena, t: AstDecl.TraitDecl) void {
        if (!t.name.isValid()) return;

        const def_id = self.addDef(.trait, t.name, DefId.INVALID);
        if (self.defs.getDef(def_id)) |d| {
            d.owner = def_id;
        }

        for (t.methods) |method| {
            self.resolveFnDecl(arena, method);
        }
    }

    fn resolveImplDecl(self: *Resolver, arena: *AstArena, impl: AstDecl.ImplDecl) void {
        const impl_scope = self.scopes.pushScope(.block, self.current_scope, DefId.INVALID);
        const prev_scope = self.current_scope;
        self.current_scope = impl_scope;

        for (impl.methods) |method| {
            self.resolveFnDecl(arena, method);
        }

        self.current_scope = prev_scope;
    }

    fn resolveTypeAlias(self: *Resolver, t: AstDecl.TypeAliasDecl) void {
        if (!t.name.isValid()) return;
        _ = self.addDef(.type_alias, t.name, DefId.INVALID);
    }

    fn resolveImport(self: *Resolver, i: AstDecl.ImportDecl) void {
        const name = if (i.alias) |alias| alias else i.path;
        if (name.isValid()) {
            _ = self.addDef(.import, name, DefId.INVALID);
        }
    }

    fn resolveExternFn(self: *Resolver, e: AstDecl.ExternFnDecl) void {
        if (!e.name.isValid()) return;
        _ = self.addDef(.function, e.name, DefId.INVALID);
    }

    fn resolveStmt(self: *Resolver, arena: *AstArena, stmt_id: StmtId) void {
        if (!stmt_id.isValid()) return;
        const stmt = arena.getStmt(stmt_id) orelse return;
        switch (stmt) {
            .let => |l| {
                self.resolvePatternDef(arena, l.pattern);
                if (l.init) |init_id| {
                    self.resolveExpr(arena, init_id);
                }
            },
            .@"var" => |v| {
                self.resolvePatternDef(arena, v.pattern);
                if (v.init) |init_id| {
                    self.resolveExpr(arena, init_id);
                }
            },
            .const_stmt => |c| {
                self.resolvePatternDef(arena, c.pattern);
                self.resolveExpr(arena, c.init);
            },
            .expr_stmt => |e| self.resolveExpr(arena, e.expr),
            .block => |b| self.resolveBlock(arena, b.stmts),
            .if_stmt => |i| {
                self.resolveExpr(arena, i.condition);
                self.resolveStmt(arena, i.then_block);
                if (i.else_branch) |eb| {
                    self.resolveStmt(arena, eb);
                }
            },
            .while_stmt => |w| {
                self.resolveExpr(arena, w.condition);
                self.resolveStmt(arena, w.body);
            },
            .for_stmt => |f| {
                self.resolveExpr(arena, f.iterable);
                const for_scope = self.scopes.pushScope(.block, self.current_scope, DefId.INVALID);
                const prev_scope = self.current_scope;
                self.current_scope = for_scope;
                if (f.iter_var.isValid()) {
                    _ = self.addDef(.local, f.iter_var, self.current_owner);
                }
                self.resolveStmt(arena, f.body);
                self.current_scope = prev_scope;
            },
            .loop_stmt => |l| self.resolveStmt(arena, l.body),
            .return_stmt => |r| {
                if (r.value) |v| self.resolveExpr(arena, v);
            },
            .break_stmt, .continue_stmt => {},
            .defer_stmt => |d| self.resolveStmt(arena, d.body),
            .errdefer_stmt => |d| self.resolveStmt(arena, d.body),
            .missing => {},
        }
    }

    fn resolveBlock(self: *Resolver, arena: *AstArena, stmts: []const StmtId) void {
        for (stmts) |stmt_id| {
            self.resolveStmt(arena, stmt_id);
        }
    }

    fn resolvePatternDef(self: *Resolver, arena: *AstArena, pat_id: PatId) void {
        if (!pat_id.isValid()) return;
        const pat = arena.getPattern(pat_id) orelse return;
        switch (pat) {
            .identifier => |i| {
                if (i.name.isValid()) {
                    _ = self.addDef(.local, i.name, self.current_owner);
                }
            },
            .tuple => |t| {
                for (t.elements) |elem| {
                    self.resolvePatternDef(arena, elem);
                }
            },
            .wildcard, .literal, .path, .missing => {},
        }
    }

    fn resolveExpr(self: *Resolver, arena: *AstArena, expr_id: ExprId) void {
        if (!expr_id.isValid()) return;
        const expr = arena.getExpr(expr_id) orelse return;
        switch (expr) {
            .identifier => |id| {
                self.resolveIdentifier(expr_id, id.name);
            },
            .binary => |b| {
                self.resolveExpr(arena, b.left);
                self.resolveExpr(arena, b.right);
            },
            .unary => |u| {
                self.resolveExpr(arena, u.operand);
            },
            .call => |c| {
                self.resolveExpr(arena, c.callee);
                for (c.args) |arg| {
                    self.resolveExpr(arena, arg);
                }
            },
            .member => |m| {
                self.resolveExpr(arena, m.object);
            },
            .index => |i| {
                self.resolveExpr(arena, i.object);
                self.resolveExpr(arena, i.index);
            },
            .paren => |p| {
                self.resolveExpr(arena, p.inner);
            },
            .if_expr => |i| {
                self.resolveExpr(arena, i.condition);
                self.resolveExpr(arena, i.then_block);
                if (i.else_branch) |eb| {
                    self.resolveExpr(arena, eb);
                }
            },
            .while_expr => |w| {
                self.resolveExpr(arena, w.condition);
                self.resolveExpr(arena, w.body);
            },
            .for_expr => |f| {
                self.resolveExpr(arena, f.iterable);
                const for_scope = self.scopes.pushScope(.block, self.current_scope, DefId.INVALID);
                const prev_scope = self.current_scope;
                self.current_scope = for_scope;
                if (f.iter_var.isValid()) {
                    _ = self.addDef(.local, f.iter_var, self.current_owner);
                }
                self.resolveExpr(arena, f.body);
                self.current_scope = prev_scope;
            },
            .loop_expr => |l| {
                self.resolveExpr(arena, l.body);
            },
            .block => |b| {
                self.resolveBlock(arena, b.stmts);
            },
            .assign => |a| {
                self.resolveExpr(arena, a.target);
                self.resolveExpr(arena, a.value);
            },
            .return_expr => |r| {
                if (r.value) |v| self.resolveExpr(arena, v);
            },
            .break_expr, .continue_expr => {},
            .closure => |c| {
                const clo_scope = self.scopes.pushScope(.closure, self.current_scope, DefId.INVALID);
                const prev_scope = self.current_scope;
                self.current_scope = clo_scope;
                for (c.params) |param| {
                    self.resolveParam(param, DefId.INVALID);
                }
                self.resolveExpr(arena, c.body);
                self.current_scope = prev_scope;
            },
            .match_expr => |m| {
                self.resolveExpr(arena, m.scrutinee);
                for (m.arms) |arm| {
                    const arm_scope = self.scopes.pushScope(.block, self.current_scope, DefId.INVALID);
                    const prev_scope = self.current_scope;
                    self.current_scope = arm_scope;
                    self.resolvePatternDef(arena, arm.pattern);
                    if (arm.guard) |g| self.resolveExpr(arena, g);
                    self.resolveExpr(arena, arm.body);
                    self.current_scope = prev_scope;
                }
            },
            .range => |r| {
                if (r.start) |s| self.resolveExpr(arena, s);
                if (r.end) |e| self.resolveExpr(arena, e);
            },
            .try_expr => |t| {
                self.resolveExpr(arena, t.operand);
            },
            .type_cast => |tc| {
                self.resolveExpr(arena, tc.operand);
            },
            .literal, .missing => {},
        }
    }

    fn resolveIdentifier(self: *Resolver, expr_id: ExprId, name: SymbolId) void {
        if (!name.isValid()) return;

        if (self.scopes.lookupInScope(self.current_scope, name)) |def_id| {
            self.refs.append(.{ .expr_id = expr_id, .def_id = def_id }) catch {};
        }
    }

    pub fn lookupDef(self: *const Resolver, name: SymbolId) ?DefId {
        return self.scopes.lookupInScope(self.current_scope, name);
    }

    pub fn resolvedCount(self: *const Resolver) usize {
        return self.refs.items.len;
    }

    pub fn defCount(self: *const Resolver) usize {
        return self.defs.defs.items.len;
    }
};
