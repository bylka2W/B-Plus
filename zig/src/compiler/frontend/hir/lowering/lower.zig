const std = @import("std");
const ast_node = @import("../../ast/ast_node.zig");
const arena_mod = @import("../../ast/arena.zig");
const resolver_mod = @import("../../resolver/resolver.zig");
const hir_mod = @import("../arena.zig");
const ids = @import("../../foundation/ids/ids.zig");
const SourceSpan = @import("../../source/location/span.zig").SourceSpan;

pub const AstExpr = ast_node.AstExpr;
pub const AstStmt = ast_node.AstStmt;
pub const AstDecl = ast_node.AstDecl;
pub const AstTypeRef = ast_node.AstTypeRef;
pub const AstPattern = ast_node.AstPattern;
pub const ParamDef = ast_node.ParamDef;

pub const AstArena = arena_mod.AstArena;
pub const AstExprId = arena_mod.ExprId;
pub const AstStmtId = arena_mod.StmtId;
pub const AstDeclId = arena_mod.DeclId;
pub const AstPatId = arena_mod.PatId;
pub const AstTypeRefId = arena_mod.TypeRefId;

pub const HirArena = hir_mod.HirArena;
pub const HirExpr = hir_mod.HirExpr;
pub const HirStmt = hir_mod.HirStmt;
pub const HirItem = hir_mod.HirItem;
pub const HirBody = hir_mod.HirBody;
pub const HirPattern = hir_mod.HirPattern;
pub const HirTy = hir_mod.HirTy;
pub const HirLiteral = @import("../literal.zig").HirLiteral;

pub const ExprId = ids.ExprId;
pub const StmtId = ids.StmtId;
pub const ItemId = ids.ItemId;
pub const PatId = ids.PatId;
pub const TypeId = ids.TypeId;
pub const DefId = ids.DefId;
pub const SymbolId = ids.SymbolId;
pub const BodyId = ids.BodyId;
pub const LabelId = ids.LabelId;

pub const BinOp = @import("../expr.zig").BinOp;
pub const UnaryOp = @import("../expr.zig").UnaryOp;
pub const LocalKind = @import("../stmt.zig").LocalKind;
pub const HirVisibility = @import("../item.zig").HirItem.HirItemKind.Visibility;

pub const UNK: TypeId = TypeId.INVALID;

pub const LowerError = error{
    OutOfMemory,
    InvalidAst,
    MissingNode,
};

pub const HirLowering = struct {
    ast: *AstArena,
    hir: *HirArena,
    resolver: *const resolver_mod.Resolver,

    pub fn init(hir: *HirArena, ast: *AstArena, resolver: *const resolver_mod.Resolver) HirLowering {
        return .{
            .ast = ast,
            .hir = hir,
            .resolver = resolver,
        };
    }

    pub fn lower(self: *HirLowering) LowerError!void {
        var i: u32 = 0;
        while (i < self.ast.declCount()) : (i += 1) {
            const decl_id = AstDeclId.new(i);
            const decl = self.ast.getDecl(decl_id) orelse continue;
            _ = try self.lowerDecl(decl_id, decl);
        }
    }

    pub fn lowerDecl(self: *HirLowering, decl_id: AstDeclId, decl: AstDecl) LowerError!ItemId {
        return switch (decl) {
            .fn_decl => |f| self.lowerFnItem(decl_id, f),
            .struct_decl => |s| self.lowerStructItem(decl_id, s),
            .enum_decl => |e| self.lowerEnumItem(decl_id, e),
            .trait_decl => |t| self.lowerTraitItem(decl_id, t),
            .impl_decl => |im| self.lowerImplItem(decl_id, im),
            .type_alias => |ta| self.lowerTypeAliasItem(decl_id, ta),
            .extern_fn => |ef| self.lowerExternFnItem(decl_id, ef),
            .import, .module, .missing => ItemId.INVALID,
        };
    }

    pub fn lowerExpr(self: *HirLowering, ast_eid: AstExprId) LowerError!ExprId {
        if (!ast_eid.isValid()) return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
        const ast_expr = self.ast.getExpr(ast_eid) orelse return self.missingExpr(.{ .file_id = 0, .start = 0, .end = 0 });
        return switch (ast_expr) {
            .literal => |l| {
                const lit_val: HirLiteral = switch (l.kind) {
                    .integer => .{ .int = 0 },
                    .float => .{ .float = 0.0 },
                    .boolean => .{ .boolean = false },
                    .string, .char, .byte, .byte_string, .null_value => .{ .int = 0 },
                };
                return try self.literal(lit_val, l.span);
            },
            .identifier => |id| return try self.path(self.lookupDef(id.name), id.span),
            .binary => |b| {
                const left = try self.lowerExpr(b.left);
                const right = try self.lowerExpr(b.right);
                return try self.binary(self.lowerBinOp(b.op), left, right, b.span);
            },
            .unary => |u| {
                const operand = try self.lowerExpr(u.operand);
                return try self.unary(self.lowerUnaryOp(u.op), operand, u.span);
            },
            .call => |c| {
                const callee = try self.lowerExpr(c.callee);
                var args = std.ArrayList(ExprId).init(self.hir.allocator());
                for (c.args) |arg| {
                    args.append(try self.lowerExpr(arg)) catch return error.OutOfMemory;
                }
                return try self.call(callee, args.toOwnedSlice() catch return error.OutOfMemory, c.span);
            },
            .member => |m| {
                const object = try self.lowerExpr(m.object);
                return self.hir.addExpr(.{ .span = m.span, .ty = UNK, .kind = .{ .field = .{ .object = object, .field = DefId.INVALID } } });
            },
            .index => |i| {
                const object = try self.lowerExpr(i.object);
                const idx = try self.lowerExpr(i.index);
                return self.hir.addExpr(.{ .span = i.span, .ty = UNK, .kind = .{ .index = .{ .object = object, .index = idx } } });
            },
            .paren => |p| return try self.lowerExpr(p.inner),
            .if_expr => |i| {
                const cond = try self.lowerExpr(i.condition);
                const then_branch = try self.lowerExpr(i.then_block);
                const else_branch = if (i.else_branch) |eb| try self.lowerExpr(eb) else try self.missingExpr(i.span);
                return try self.ifExpr(cond, then_branch, else_branch, i.span);
            },
            .while_expr => |w| {
                const cond = try self.lowerExpr(w.condition);
                const body = try self.lowerExpr(w.body);
                return try self.whileExpr(cond, body, w.span);
            },
            .for_expr => |f| {
                const iterable = try self.lowerExpr(f.iterable);
                const body = try self.lowerExpr(f.body);
                return try self.forExpr(self.resolveName(f.iter_var), iterable, body, f.span);
            },
            .loop_expr => |l| {
                const body = try self.lowerExpr(l.body);
                return try self.loopExpr(body, l.span);
            },
            .block => |b| {
                const stmts = try self.lowerStmtSlice(b.stmts);
                const last = if (stmts.len > 0) blk: {
                    const last_sid = stmts[stmts.len - 1];
                    const stmt = self.hir.getStmt(last_sid) orelse break :blk try self.missingExpr(b.span);
                    if (stmt.kind == .expr) break :blk stmt.kind.expr.expr;
                    break :blk try self.missingExpr(b.span);
                } else try self.missingExpr(b.span);
                return try self.block(stmts, last, b.span);
            },
            .assign => |a| {
                const target = try self.lowerExpr(a.target);
                const value = try self.lowerExpr(a.value);
                return try self.assign(target, value, a.span);
            },
            .return_expr => |r| {
                const value = if (r.value) |v| try self.lowerExpr(v) else try self.missingExpr(r.span);
                return try self.returnExpr(value, r.span);
            },
            .break_expr => |b| return try self.breakExpr(LabelId.INVALID, try self.missingExpr(b.span), b.span),
            .continue_expr => |c| return try self.continueExpr(LabelId.INVALID, c.span),
            .range => |r| {
                const start = if (r.start) |s| try self.lowerExpr(s) else try self.missingExpr(r.span);
                const end = if (r.end) |e| try self.lowerExpr(e) else try self.missingExpr(r.span);
                return self.hir.addExpr(.{ .span = r.span, .ty = UNK, .kind = .{ .range = .{ .start = start, .end = end, .inclusive = r.inclusive } } });
            },
            .try_expr => |t| return try self.lowerExpr(t.operand),
            .type_cast => |tc| {
                const operand = try self.lowerExpr(tc.operand);
                const target_type = try self.lowerTypeRefId(tc.target_type);
                return self.hir.addExpr(.{ .span = tc.span, .ty = UNK, .kind = .{ .type_cast = .{ .operand = operand, .target_type = target_type } } });
            },
            .match_expr => {
                return try self.lowerMatchExpr(ast_eid);
            },
            .closure => {
                return try self.lowerClosureExpr(ast_eid);
            },
            .missing => |m| return try self.missingExpr(m.span),
        };
    }

    pub fn lowerStmt(self: *HirLowering, ast_sid: AstStmtId) LowerError!StmtId {
        if (!ast_sid.isValid()) return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
        const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
        return switch (ast_stmt) {
            .let => self.lowerLocalDecl(ast_sid),
            .@"var" => self.lowerLocalDecl(ast_sid),
            .const_stmt => self.lowerLocalDecl(ast_sid),
            .expr_stmt => self.lowerExprStmt(ast_sid),
            .block => self.lowerBlockStmt(ast_sid),
            .if_stmt => self.lowerIfStmt(ast_sid),
            .while_stmt => self.lowerWhileStmt(ast_sid),
            .for_stmt => self.lowerForStmt(ast_sid),
            .loop_stmt => self.lowerLoopStmt(ast_sid),
            .return_stmt => self.lowerReturnStmt(ast_sid),
            .break_stmt => self.lowerBreakStmt(ast_sid),
            .continue_stmt => self.lowerContinueStmt(ast_sid),
            .defer_stmt => self.lowerDeferStmt(ast_sid),
            .errdefer_stmt => self.lowerDeferStmt(ast_sid),
            .missing => self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
        };
    }

    pub fn lookupDef(self: *const HirLowering, name: SymbolId) DefId {
        if (self.resolver.defs.lookupName(name)) |def_id| {
            return def_id;
        }
        return DefId.INVALID;
    }

    pub usingnamespace @import("common.zig");
    pub usingnamespace @import("builder.zig");
    pub usingnamespace @import("types.zig");
    pub usingnamespace @import("patterns.zig");
    pub usingnamespace @import("bodies.zig");
    pub usingnamespace @import("expr/match.zig");
    pub usingnamespace @import("expr/closure.zig");
    pub usingnamespace @import("item/function.zig");
    pub usingnamespace @import("item/struct.zig");
    pub usingnamespace @import("item/enum.zig");
    pub usingnamespace @import("item/trait.zig");
    pub usingnamespace @import("item/impl.zig");
    pub usingnamespace @import("item/module.zig");
    pub usingnamespace @import("item/state.zig");
    pub usingnamespace @import("item/kernel.zig");
    pub usingnamespace @import("stmt/local.zig");
    pub usingnamespace @import("stmt/block.zig");
    pub usingnamespace @import("stmt/loops.zig");
    pub usingnamespace @import("stmt/control.zig");
    pub usingnamespace @import("stmt/expr.zig");
};
