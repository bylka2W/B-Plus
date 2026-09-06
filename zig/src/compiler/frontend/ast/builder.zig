const std = @import("std");
const ast_node = @import("ast_node.zig");
const arena_mod = @import("arena.zig");
const syntax_mod = @import("../syntax/red/syntax_node.zig");
const green_node_mod = @import("../syntax/green/green_node.zig");
const token_kind = @import("../syntax/token/token_kind.zig");
const keyword_mod = @import("../syntax/token/keyword.zig");
const ids = @import("../foundation/ids/ids.zig");

pub const SyntaxNode = syntax_mod.SyntaxNode;
pub const SyntaxToken = syntax_mod.SyntaxToken;
pub const SyntaxElement = syntax_mod.SyntaxElement;
pub const SyntaxKind = green_node_mod.SyntaxKind;
pub const AstArena = arena_mod.AstArena;
pub const ExprId = ast_node.ExprId;
pub const StmtId = ast_node.StmtId;
pub const DeclId = ast_node.DeclId;
pub const PatId = ast_node.PatId;
pub const TypeRefId = ast_node.TypeRefId;
pub const SymbolId = ids.SymbolId;
pub const AstExpr = ast_node.AstExpr;
pub const AstStmt = ast_node.AstStmt;
pub const AstDecl = ast_node.AstDecl;
pub const AstTypeRef = ast_node.AstTypeRef;
pub const AstPattern = ast_node.AstPattern;

pub const AstBuilder = struct {
    arena: *AstArena,
    symbol_map: std.StringHashMap(u32),
    stmts_as_items: std.ArrayList(ast_node.AstItem),

    pub fn init(arena: *AstArena) AstBuilder {
        return .{
            .arena = arena,
            .symbol_map = std.StringHashMap(u32).init(arena.allocator),
            .stmts_as_items = std.ArrayList(ast_node.AstItem).init(arena.allocator),
        };
    }

    pub fn deinit(self: *AstBuilder) void {
        self.symbol_map.deinit();
        self.stmts_as_items.deinit();
    }

    pub fn internName(self: *AstBuilder, text: []const u8) SymbolId {
        const gop = self.symbol_map.getOrPut(text) catch return SymbolId.INVALID;
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.symbol_map.count() - 1);
        }
        return SymbolId.new(gop.value_ptr.*);
    }

    pub fn lowerSourceFile(self: *AstBuilder, node: SyntaxNode) std.ArrayList(DeclId) {
        var items = std.ArrayList(DeclId).init(self.arena.allocator);
        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child.asNode()) |childNode| {
                if (self.lowerItem(childNode)) |item| {
                    items.append(item) catch break;
                }
            }
        }
        return items;
    }

    pub fn lowerItem(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        return switch (node.kind()) {
            .fn_decl => self.lowerFnDecl(node),
            .struct_decl => self.lowerStructDecl(node),
            .enum_decl => self.lowerEnumDecl(node),
            .trait_decl => self.lowerTraitDecl(node),
            .impl_decl => self.lowerImplDecl(node),
            .type_decl => self.lowerTypeAlias(node),
            .import_decl => self.lowerImport(node),
            .expr_stmt, .let_stmt, .var_stmt, .const_stmt, .if_stmt, .while_stmt,
            .for_stmt, .loop_stmt, .return_stmt, .break_stmt, .continue_stmt,
            .defer_stmt, .errdefer_stmt, .block_stmt,
            => {
                self.stmts_as_items.append(.{ .statement = self.lowerStmt(node) }) catch {};
                return null;
            },
            else => null,
        };
    }

    pub fn lowerFnDecl(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        var name: SymbolId = SymbolId.INVALID;
        var params = std.ArrayList(ast_node.ParamDef).init(self.arena.allocator);
        var return_type: ?TypeRefId = null;
        var body: ?StmtId = null;
        const vis: ast_node.Visibility = .private;
        const is_extern_val = false;
        var seen_fn = false;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            switch (child.kind()) {
                .kw_fn => {
                    seen_fn = true;
                },
                .identifier => {
                    if (seen_fn and !name.isValid()) {
                        name = self.internName(self.firstIdentifierText(child));
                    }
                },
                .param_list => {
                    if (child.asNode()) |paramListNode| {
                        var param_iter = paramListNode.allChildren();
                        while (param_iter.next()) |param_el| {
                            if (param_el.kind() == .param) {
                                if (param_el.asNode()) |paramNode| {
                                    if (self.lowerParam(paramNode)) |p| {
                                        params.append(p) catch break;
                                    }
                                }
                            }
                        }
                    }
                },
                .type_ref => {
                    if (return_type == null) {
                        if (child.asNode()) |typeNode| {
                            return_type = self.lowerTypeRef(typeNode);
                        }
                    }
                },
                .block_stmt, .block_expr => {
                    if (child.asNode()) |blockNode| {
                        body = self.lowerBlockAsStmt(blockNode);
                    }
                },
                else => {},
            }
        }

        const decl = AstDecl{
            .fn_decl = .{
                .name = name,
                .params = params.toOwnedSlice() catch &.{},
                .return_type = return_type,
                .body = body,
                .visibility = vis,
                .is_extern = is_extern_val,
                .span = self.nodeSpan(node),
            },
        };
        return self.arena.addDecl(decl);
    }

    pub fn lowerStructDecl(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        var name: SymbolId = SymbolId.INVALID;
        var fields = std.ArrayList(ast_node.FieldDef).init(self.arena.allocator);

        var iter = node.allChildren();
        while (iter.next()) |child| {
            switch (child.kind()) {
                .identifier => {
                    if (!name.isValid()) {
                        name = self.internName(self.firstIdentifierText(child));
                    }
                },
                .field => {
                    if (child.asNode()) |field_node| {
                        if (self.lowerField(field_node)) |f| {
                            fields.append(f) catch break;
                        }
                    }
                },
                else => {},
            }
        }

        const decl = AstDecl{
            .struct_decl = .{
                .name = name,
                .fields = fields.toOwnedSlice() catch &.{},
                .visibility = .private,
                .span = self.nodeSpan(node),
            },
        };
        return self.arena.addDecl(decl);
    }

    pub fn lowerEnumDecl(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        var name: SymbolId = SymbolId.INVALID;
        var variants = std.ArrayList(ast_node.VariantDef).init(self.arena.allocator);

        var iter = node.allChildren();
        while (iter.next()) |child| {
            switch (child.kind()) {
                .identifier => {
                    if (!name.isValid()) {
                        name = self.internName(self.firstIdentifierText(child));
                    }
                },
                .variant_list => {
                    if (child.asNode()) |list_node| {
                        var viter = list_node.allChildren();
                        while (viter.next()) |vchild| {
                            if (vchild.kind() == .variant) {
                                if (vchild.asNode()) |variant_node| {
                                    var vname: SymbolId = SymbolId.INVALID;
                                    var child_iter = variant_node.allChildren();
                                    while (child_iter.next()) |vc| {
                                        if (vc.kind() == .identifier and !vname.isValid()) {
                                            vname = self.internName(self.firstIdentifierText(vc));
                                        }
                                    }
                                    variants.append(.{ .name = vname, .fields = &.{}, .span = self.nodeSpan(variant_node) }) catch break;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        const decl = AstDecl{
            .enum_decl = .{
                .name = name,
                .variants = variants.toOwnedSlice() catch &.{},
                .visibility = .private,
                .span = self.nodeSpan(node),
            },
        };
        return self.arena.addDecl(decl);
    }

    pub fn lowerTraitDecl(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        var name: SymbolId = SymbolId.INVALID;
        var methods = std.ArrayList(AstDecl.FnDecl).init(self.arena.allocator);

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .identifier and !name.isValid()) {
                name = self.internName(self.firstIdentifierText(child));
            } else if (child.kind() == .fn_decl) {
                if (self.lowerFnDecl(child)) |did| {
                    if (self.arena.getDecl(did)) |d| {
                        switch (d) {
                            .fn_decl => |fn_decl| {
                                methods.append(fn_decl) catch break;
                            },
                            else => {},
                        }
                    }
                }
            }
        }

        const decl = AstDecl{
            .trait_decl = .{
                .name = name,
                .methods = methods.toOwnedSlice() catch &.{},
                .visibility = .private,
                .span = self.nodeSpan(node),
            },
        };
        return self.arena.addDecl(decl);
    }

    pub fn lowerImplDecl(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        var self_type: ?TypeRefId = null;
        var trait_ref: ?TypeRefId = null;
        var methods = std.ArrayList(AstDecl.FnDecl).init(self.arena.allocator);

        var iter = node.childNodes();
        while (iter.next()) |child| {
            switch (child.kind()) {
                .named_type, .type_ref => {
                    if (self_type == null) {
                        self_type = self.lowerTypeRef(child);
                    } else {
                        trait_ref = self.lowerTypeRef(child);
                    }
                },
                .fn_decl => {
                    if (self.lowerFnDecl(child)) |did| {
                        if (self.arena.getDecl(did)) |d| {
                            switch (d) {
                                .fn_decl => |fn_decl| {
                                    methods.append(fn_decl) catch break;
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }

        const st = self_type orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } });

        const decl = AstDecl{
            .impl_decl = .{
                .self_type = st,
                .trait_ref = trait_ref,
                .methods = methods.toOwnedSlice() catch &.{},
                .span = self.nodeSpan(node),
            },
        };
        return self.arena.addDecl(decl);
    }

    pub fn lowerTypeAlias(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        var name: SymbolId = SymbolId.INVALID;
        var target: ?TypeRefId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .identifier and !name.isValid()) {
                name = self.internName(self.firstIdentifierText(child));
            } else if (child.kind() == .type_ref and target == null) {
                target = self.lowerTypeRef(child);
            }
        }

        const tr = target orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } });

        const decl = AstDecl{
            .type_alias = .{
                .name = name,
                .target_type = tr,
                .visibility = .private,
                .span = self.nodeSpan(node),
            },
        };
        return self.arena.addDecl(decl);
    }

    pub fn lowerImport(self: *AstBuilder, node: SyntaxNode) ?DeclId {
        var path: SymbolId = SymbolId.INVALID;
        var alias: ?SymbolId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .identifier and !path.isValid()) {
                path = self.internName(self.firstIdentifierText(child));
            } else if (child.kind() == .identifier) {
                alias = self.internName(self.firstIdentifierText(child));
            }
        }

        const decl = AstDecl{
            .import = .{
                .path = path,
                .alias = alias,
                .span = self.nodeSpan(node),
            },
        };
        return self.arena.addDecl(decl);
    }

    pub fn lowerParam(self: *AstBuilder, node: SyntaxNode) ?ast_node.ParamDef {
        var name: SymbolId = SymbolId.INVALID;
        var type_ref: ?TypeRefId = null;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child.kind() == .identifier and !name.isValid()) {
                name = self.internName(self.firstIdentifierText(child));
            } else if (child.kind() == .type_ref) {
                if (child.asNode()) |n| {
                    type_ref = self.lowerTypeRef(n);
                }
            }
        }

        return .{
            .name = name,
            .type_ref = type_ref,
            .span = self.nodeSpan(node),
        };
    }

    pub fn lowerField(self: *AstBuilder, node: SyntaxNode) ?ast_node.FieldDef {
        var name: SymbolId = SymbolId.INVALID;
        var type_ref: ?TypeRefId = null;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            switch (child.kind()) {
                .identifier => {
                    if (!name.isValid()) {
                        name = self.internName(self.firstIdentifierText(child));
                    }
                },
                .type_ref => {
                    if (child.asNode()) |type_node| {
                        type_ref = self.lowerTypeRef(type_node);
                    }
                },
                else => {},
            }
        }

        return .{
            .name = name,
            .type_ref = type_ref orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .visibility = .private,
            .span = self.nodeSpan(node),
        };
    }

    pub fn lowerStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        return switch (node.kind()) {
            .let_stmt => self.lowerLetStmt(node),
            .var_stmt => self.lowerVarStmt(node),
            .const_stmt => self.lowerConstStmt(node),
            .expr_stmt => self.lowerExprStmt(node),
            .block_stmt => self.lowerBlockAsStmt(node),
            .if_stmt => self.lowerIfStmt(node),
            .while_stmt => self.lowerWhileStmt(node),
            .for_stmt => self.lowerForStmt(node),
            .loop_stmt => self.lowerLoopStmt(node),
            .return_stmt => self.lowerReturnStmt(node),
            .break_stmt => self.arena.addStmt(.{ .break_stmt = .{ .label = null, .span = self.nodeSpan(node) } }),
            .continue_stmt => self.arena.addStmt(.{ .continue_stmt = .{ .label = null, .span = self.nodeSpan(node) } }),
            else => self.arena.addStmt(.{ .expr_stmt = .{ .expr = self.lowerExpr(node), .span = self.nodeSpan(node) } }),
        };
    }

    fn lowerLetStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var pat: PatId = PatId.INVALID;
        var type_ann: ?TypeRefId = null;
        var init_expr: ?ExprId = null;
        var after_eq = false;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child.kind() == .eq) {
                after_eq = true;
                continue;
            }
            if (!after_eq) {
                if (child.kind() == .identifier_pat) {
                    if (child.asNode()) |n| {
                        pat = self.arena.addPattern(.{ .identifier = .{
                            .name = self.internName(self.firstIdentifierText(n)),
                            .mutable = false,
                            .span = self.nodeSpan(n),
                        } });
                    }
                } else if (child.kind() == .type_ref) {
                    if (child.asNode()) |n| {
                        type_ann = self.lowerTypeRef(n);
                    }
                }
            } else if (init_expr == null) {
                if (child.asNode()) |n| {
                    init_expr = self.lowerExpr(n);
                }
            }
        }

        return self.arena.addStmt(.{ .let = .{
            .pattern = if (pat.isValid()) pat else self.arena.addPattern(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .type_annotation = type_ann,
            .init = init_expr,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerVarStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        return self.lowerLetStmt(node);
    }

    fn lowerConstStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var pat: PatId = PatId.INVALID;
        var type_ann: ?TypeRefId = null;
        var init_expr: ?ExprId = null;
        var after_eq = false;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child.kind() == .eq) {
                after_eq = true;
                continue;
            }
            if (!after_eq) {
                if (child.kind() == .identifier_pat) {
                    if (child.asNode()) |n| {
                        pat = self.arena.addPattern(.{ .identifier = .{
                            .name = self.internName(self.firstIdentifierText(n)),
                            .mutable = false,
                            .span = self.nodeSpan(n),
                        } });
                    }
                } else if (child.kind() == .type_ref) {
                    if (child.asNode()) |n| {
                        type_ann = self.lowerTypeRef(n);
                    }
                }
            } else if (init_expr == null) {
                if (child.asNode()) |n| {
                    init_expr = self.lowerExpr(n);
                }
            }
        }

        const init_val = init_expr orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } });

        return self.arena.addStmt(.{ .const_stmt = .{
            .pattern = if (pat.isValid()) pat else self.arena.addPattern(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .type_annotation = type_ann,
            .init = init_val,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerExprStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var expr_id: ?ExprId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (expr_id == null) {
                expr_id = self.lowerExpr(child);
            }
        }
        return self.arena.addStmt(.{ .expr_stmt = .{
            .expr = expr_id orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerBlockAsStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var stmts = std.ArrayList(StmtId).init(self.arena.allocator);
        var iter = node.childNodes();
        while (iter.next()) |child| {
            const sid = self.lowerStmt(child);
            stmts.append(sid) catch break;
        }
        return self.arena.addStmt(.{ .block = .{
            .stmts = stmts.toOwnedSlice() catch &.{},
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerIfStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var cond: ?ExprId = null;
        var then: ?StmtId = null;
        var els: ?StmtId = null;
        var phase: u2 = 0;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child.kind() == .kw_else) {
                phase = 2;
                continue;
            }
            const child_node = child.asNode() orelse continue;
            switch (phase) {
                0 => cond = self.lowerExpr(child_node),
                1 => then = self.lowerStmt(child_node),
                2 => els = self.lowerStmt(child_node),
                else => {},
            }
            if (phase == 0 and cond != null) phase = 1;
        }

        return self.arena.addStmt(.{ .if_stmt = .{
            .condition = cond orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .then_block = then orelse self.arena.addStmt(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .else_branch = els,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerWhileStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var cond: ?ExprId = null;
        var body: ?StmtId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (cond == null) {
                cond = self.lowerExpr(child);
            } else if (body == null) {
                body = self.lowerStmt(child);
            }
        }

        return self.arena.addStmt(.{ .while_stmt = .{
            .condition = cond orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .body = body orelse self.arena.addStmt(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerForStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var iter_var: SymbolId = SymbolId.INVALID;
        var iterable: ?ExprId = null;
        var body: ?StmtId = null;
        var phase: u2 = 0;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child.kind() == .kw_in) {
                phase = 1;
                continue;
            }
            switch (phase) {
                0 => {
                    if (child.kind() == .identifier) {
                        iter_var = self.internName(self.firstIdentifierText(child));
                    }
                },
                1 => {
                    if (child.asNode()) |n| {
                        iterable = self.lowerExpr(n);
                    }
                },
                2 => {
                    if (child.asNode()) |n| {
                        body = self.lowerStmt(n);
                    }
                },
                else => {},
            }
            if (phase == 1 and iterable != null) phase = 2;
        }

        return self.arena.addStmt(.{ .for_stmt = .{
            .iter_var = iter_var,
            .iterable = iterable orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .body = body orelse self.arena.addStmt(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerLoopStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var body: ?StmtId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (body == null) {
                body = self.lowerStmt(child);
            }
        }
        return self.arena.addStmt(.{ .loop_stmt = .{
            .body = body orelse self.arena.addStmt(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerReturnStmt(self: *AstBuilder, node: SyntaxNode) StmtId {
        var value: ?ExprId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (value == null) {
                value = self.lowerExpr(child);
            }
        }
        return self.arena.addStmt(.{ .return_stmt = .{
            .value = value,
            .span = self.nodeSpan(node),
        } });
    }

    pub fn lowerExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        return switch (node.kind()) {
            .literal_expr, .int_literal, .float_literal, .string_literal, .char_literal,
            .byte_literal, .byte_string_literal, .true_literal, .false_literal, .null_literal,
            => self.lowerLiteral(node),
            .identifier_expr, .identifier => self.lowerIdentifier(node),
            .binary_expr => self.lowerBinaryExpr(node),
            .unary_expr => self.lowerUnaryExpr(node),
            .call_expr => self.lowerCallExpr(node),
            .member_expr => self.lowerMemberExpr(node),
            .index_expr => self.lowerIndexExpr(node),
            .paren_expr => self.lowerParenExpr(node),
            .if_expr => self.lowerIfExpr(node),
            .while_expr => self.lowerWhileExpr(node),
            .for_expr => self.lowerForExpr(node),
            .loop_expr => self.lowerLoopExpr(node),
            .block_expr => self.lowerBlockExpr(node),
            .return_expr => self.lowerReturnExpr(node),
            .break_expr => self.arena.addExpr(.{ .break_expr = .{ .label = null, .span = self.nodeSpan(node) } }),
            .continue_expr => self.arena.addExpr(.{ .continue_expr = .{ .label = null, .span = self.nodeSpan(node) } }),
            .assign_expr => self.lowerAssignExpr(node),
            .range_expr => self.lowerRangeExpr(node),
            .try_expr => self.lowerTryExpr(node),
            .type_cast => self.lowerTypeCastExpr(node),
            .closure_expr => self.lowerClosureExpr(node),
            .match_expr => self.lowerMatchExpr(node),
            else => self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
        };
    }

    fn lowerLiteral(self: *AstBuilder, node: SyntaxNode) ExprId {
        const text = self.firstTokenText(node);
        const kind: ast_node.LiteralKind = switch (node.kind()) {
            .true_literal, .false_literal => .boolean,
            .null_literal => .null_value,
            .int_literal => .integer,
            .float_literal => .float,
            .string_literal => .string,
            .char_literal => .char,
            .byte_literal => .byte,
            .byte_string_literal => .byte_string,
            .literal_expr => blk: {
                if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) break :blk .boolean;
                if (std.mem.eql(u8, text, "null")) break :blk .null_value;
                if (std.mem.indexOf(u8, text, ".") != null) break :blk .float;
                break :blk .integer;
            },
            else => .integer,
        };
        return self.arena.addExpr(.{ .literal = .{
            .kind = kind,
            .symbol_id = self.internName(text).index,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerIdentifier(self: *AstBuilder, node: SyntaxNode) ExprId {
        return self.arena.addExpr(.{ .identifier = .{
            .name = self.internName(self.tokenText(node)),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerBinaryExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var op: ast_node.BinOp = .add;
        var left: ?ExprId = null;
        var right: ?ExprId = null;
        var phase: u2 = 0;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child == .token) {
                op = self.syntaxKindToBinOp(child.token.kind());
            } else if (child.asNode()) |child_node| {
                const eid = self.lowerExpr(child_node);
                if (phase == 0) {
                    left = eid;
                    phase = 1;
                } else {
                    right = eid;
                }
            }
        }

        return self.arena.addExpr(.{ .binary = .{
            .op = op,
            .left = left orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .right = right orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerUnaryExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var op: ast_node.UnaryOp = .negate;
        var operand: ?ExprId = null;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child == .token) {
                op = self.syntaxKindToUnaryOp(child.token.kind());
            } else if (child.asNode()) |child_node| {
                if (operand == null) {
                    operand = self.lowerExpr(child_node);
                }
            }
        }

        return self.arena.addExpr(.{ .unary = .{
            .op = op,
            .operand = operand orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerCallExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var callee: ?ExprId = null;
        var args = std.ArrayList(ExprId).init(self.arena.allocator);

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (callee == null) {
                callee = self.lowerExpr(child);
            } else {
                args.append(self.lowerExpr(child)) catch break;
            }
        }

        return self.arena.addExpr(.{ .call = .{
            .callee = callee orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .args = args.toOwnedSlice() catch &.{},
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerMemberExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var object: ?ExprId = null;
        var member: SymbolId = SymbolId.INVALID;

        var iter = node.allChildren();
        while (iter.next()) |child| {
            if (child == .token) {
                if (child.token.kind() == .identifier) {
                    member = self.internName(self.firstIdentifierText(child.token));
                }
            } else if (child.asNode()) |child_node| {
                if (object == null) {
                    object = self.lowerExpr(child_node);
                }
            }
        }

        return self.arena.addExpr(.{ .member = .{
            .object = object orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .member = member,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerIndexExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var object: ?ExprId = null;
        var index: ?ExprId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (object == null) {
                object = self.lowerExpr(child);
            } else if (index == null) {
                index = self.lowerExpr(child);
            }
        }

        return self.arena.addExpr(.{ .index = .{
            .object = object orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .index = index orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerParenExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var inner: ?ExprId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (inner == null) {
                inner = self.lowerExpr(child);
            }
        }
        return self.arena.addExpr(.{ .paren = .{
            .inner = inner orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerIfExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var cond: ?ExprId = null;
        var then_block: ?ExprId = null;
        var else_branch: ?ExprId = null;
        var phase: u2 = 0;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .kw_else) {
                phase = 2;
                continue;
            }
            switch (phase) {
                0 => cond = self.lowerExpr(child),
                1 => then_block = self.lowerExpr(child),
                2 => else_branch = self.lowerExpr(child),
                else => {},
            }
            if (phase == 0 and cond != null) phase = 1;
        }

        return self.arena.addExpr(.{ .if_expr = .{
            .condition = cond orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .then_block = then_block orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .else_branch = else_branch,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerWhileExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var cond: ?ExprId = null;
        var body: ?ExprId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (cond == null) {
                cond = self.lowerExpr(child);
            } else if (body == null) {
                body = self.lowerExpr(child);
            }
        }

        return self.arena.addExpr(.{ .while_expr = .{
            .condition = cond orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .body = body orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerForExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var iter_var: SymbolId = SymbolId.INVALID;
        var iterable: ?ExprId = null;
        var body: ?ExprId = null;
        var phase: u2 = 0;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .kw_in) {
                phase = 1;
                continue;
            }
            switch (phase) {
                0 => {
                    if (child.kind() == .identifier) iter_var = self.internName(self.firstIdentifierText(child));
                },
                1 => iterable = self.lowerExpr(child),
                2 => body = self.lowerExpr(child),
                else => {},
            }
            if (phase == 1 and iterable != null) phase = 2;
        }

        return self.arena.addExpr(.{ .for_expr = .{
            .iter_var = iter_var,
            .iterable = iterable orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .body = body orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerLoopExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var body: ?ExprId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (body == null) body = self.lowerExpr(child);
        }
        return self.arena.addExpr(.{ .loop_expr = .{
            .body = body orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerBlockExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var stmts = std.ArrayList(StmtId).init(self.arena.allocator);
        var iter = node.childNodes();
        while (iter.next()) |child| {
            stmts.append(self.lowerStmt(child)) catch break;
        }
        return self.arena.addExpr(.{ .block = .{
            .stmts = stmts.toOwnedSlice() catch &.{},
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerReturnExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var value: ?ExprId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (value == null) value = self.lowerExpr(child);
        }
        return self.arena.addExpr(.{ .return_expr = .{ .value = value, .span = self.nodeSpan(node) } });
    }

    fn lowerAssignExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var target: ?ExprId = null;
        var value: ?ExprId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (target == null) {
                target = self.lowerExpr(child);
            } else if (value == null) {
                value = self.lowerExpr(child);
            }
        }

        return self.arena.addExpr(.{ .assign = .{
            .target = target orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .value = value orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerRangeExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var start: ?ExprId = null;
        var end: ?ExprId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (start == null) {
                start = self.lowerExpr(child);
            } else if (end == null) {
                end = self.lowerExpr(child);
            }
        }

        return self.arena.addExpr(.{ .range = .{
            .start = start,
            .end = end,
            .inclusive = false,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerTryExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var operand: ?ExprId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (operand == null) operand = self.lowerExpr(child);
        }
        return self.arena.addExpr(.{ .try_expr = .{
            .operand = operand orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerTypeCastExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var operand: ?ExprId = null;
        var target: ?TypeRefId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .type_ref or child.kind() == .named_type) {
                target = self.lowerTypeRef(child);
            } else if (operand == null) {
                operand = self.lowerExpr(child);
            }
        }

        return self.arena.addExpr(.{ .type_cast = .{
            .operand = operand orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .target_type = target orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerClosureExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var params = std.ArrayList(ast_node.ParamDef).init(self.arena.allocator);
        var return_type: ?TypeRefId = null;
        var body: ?ExprId = null;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .identifier) {
                params.append(.{ .name = self.internName(self.firstIdentifierText(child)), .type_ref = null, .span = self.nodeSpan(child) }) catch break;
            } else if (child.kind() == .type_ref) {
                return_type = self.lowerTypeRef(child);
            } else if (child.kind() == .block_expr) {
                body = self.lowerExpr(child);
            }
        }

        return self.arena.addExpr(.{ .closure = .{
            .params = params.toOwnedSlice() catch &.{},
            .return_type = return_type,
            .body = body orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerMatchExpr(self: *AstBuilder, node: SyntaxNode) ExprId {
        var scrutinee: ?ExprId = null;
        var arms = std.ArrayList(AstExpr.MatchArm).init(self.arena.allocator);

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .match_expr)
            {
                var pat_id: PatId = PatId.INVALID;
                var arm_body: ?ExprId = null;
                var arm_iter = child.childNodes();
                while (arm_iter.next()) |ac| {
                    if (ac.kind() == .identifier) {
                        pat_id = self.arena.addPattern(.{ .identifier = .{
                            .name = self.internName(self.tokenText(ac)),
                            .mutable = false,
                            .span = self.nodeSpan(ac),
                        } });
                    } else if (arm_body == null) {
                        arm_body = self.lowerExpr(ac);
                    }
                }
                arms.append(.{
                    .pattern = if (pat_id.isValid()) pat_id else self.arena.addPattern(.{ .missing = .{ .span = self.nodeSpan(child) } }),
                    .guard = null,
                    .body = arm_body orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(child) } }),
                }) catch break;
            } else if (scrutinee == null) {
                scrutinee = self.lowerExpr(child);
            }
        }

        return self.arena.addExpr(.{ .match_expr = .{
            .scrutinee = scrutinee orelse self.arena.addExpr(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .arms = arms.toOwnedSlice() catch &.{},
            .span = self.nodeSpan(node),
        } });
    }

    pub fn lowerTypeRef(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        return switch (node.kind()) {
            .named_type => self.lowerNamedType(node),
            .type_ref => {
                var iter = node.childNodes();
                while (iter.next()) |child| {
                    return self.lowerTypeRef(child);
                }
                return self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } });
            },
            .pointer_type => self.lowerPointerType(node),
            .array_type => self.lowerArrayType(node),
            .slice_type => self.lowerSliceType(node),
            .tuple_type => self.lowerTupleType(node),
            .fn_type => self.lowerFnType(node),
            .optional_type => self.lowerOptionalType(node),
            else => self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
        };
    }

    fn lowerNamedType(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        var name: SymbolId = SymbolId.INVALID;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .identifier and !name.isValid()) {
                name = self.internName(self.firstIdentifierText(child));
            }
        }
        return self.arena.addTypeRef(.{ .named = .{
            .name = name,
            .type_args = &.{},
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerPointerType(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        var mutable = false;
        var pointee: ?TypeRefId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .kw_mut) {
                mutable = true;
            } else if (child.kind() == .type_ref or child.kind() == .named_type) {
                pointee = self.lowerTypeRef(child);
            }
        }
        return self.arena.addTypeRef(.{ .pointer = .{
            .mutable = mutable,
            .pointee = pointee orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerArrayType(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        var element: ?TypeRefId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .type_ref or child.kind() == .named_type) {
                element = self.lowerTypeRef(child);
            }
        }
        return self.arena.addTypeRef(.{ .array = .{
            .element = element orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .length = null,
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerSliceType(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        var element: ?TypeRefId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .type_ref or child.kind() == .named_type) {
                element = self.lowerTypeRef(child);
            }
        }
        return self.arena.addTypeRef(.{ .slice = .{
            .element = element orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerTupleType(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        var elements = std.ArrayList(TypeRefId).init(self.arena.allocator);
        var iter = node.childNodes();
        while (iter.next()) |child| {
            elements.append(self.lowerTypeRef(child)) catch break;
        }
        return self.arena.addTypeRef(.{ .tuple = .{
            .elements = elements.toOwnedSlice() catch &.{},
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerFnType(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        var params = std.ArrayList(TypeRefId).init(self.arena.allocator);
        var return_type: ?TypeRefId = null;
        var after_arrow = false;

        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .arrow) {
                after_arrow = true;
                continue;
            }
            if (child.kind() == .type_ref or child.kind() == .named_type) {
                if (after_arrow) {
                    return_type = self.lowerTypeRef(child);
                } else {
                    params.append(self.lowerTypeRef(child)) catch break;
                }
            }
        }

        return self.arena.addTypeRef(.{ .fn_type = .{
            .params = params.toOwnedSlice() catch &.{},
            .return_type = return_type orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn lowerOptionalType(self: *AstBuilder, node: SyntaxNode) TypeRefId {
        var inner: ?TypeRefId = null;
        var iter = node.childNodes();
        while (iter.next()) |child| {
            if (child.kind() == .type_ref or child.kind() == .named_type) {
                inner = self.lowerTypeRef(child);
            }
        }
        return self.arena.addTypeRef(.{ .optional = .{
            .inner = inner orelse self.arena.addTypeRef(.{ .missing = .{ .span = self.nodeSpan(node) } }),
            .span = self.nodeSpan(node),
        } });
    }

    fn syntaxKindToBinOp(self: *AstBuilder, kind: SyntaxKind) ast_node.BinOp {
        _ = self;
        return switch (kind) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .eq_eq => .eq,
            .bang_eq => .ne,
            .less => .lt,
            .greater => .gt,
            .less_eq => .le,
            .greater_eq => .ge,
            .amp_amp => .and_,
            .pipe_pipe => .or_,
            .amp => .bitwise_and,
            .pipe => .bitwise_or,
            .caret => .bitwise_xor,
            .shl => .shl,
            .shr => .shr,
            .eq => .assign,
            .plus_eq => .assign_add,
            .minus_eq => .assign_sub,
            .star_eq => .assign_mul,
            .slash_eq => .assign_div,
            .percent_eq => .assign_mod,
            .dot_dot => .range,
            .dot_dot_eq => .range_inclusive,
            else => .add,
        };
    }

    fn syntaxKindToUnaryOp(self: *AstBuilder, kind: SyntaxKind) ast_node.UnaryOp {
        _ = self;
        return switch (kind) {
            .minus => .negate,
            .bang => .not,
            .tilde => .bitwise_not,
            .star => .deref,
            .amp => .address,
            .kw_ref => .ref,
            else => .negate,
        };
    }

    fn firstIdentifierText(self: *AstBuilder, node_or_token: anytype) []const u8 {
        _ = self;
        const T = @TypeOf(node_or_token);
        if (T == SyntaxNode) {
            var iter = node_or_token.childTokens();
            while (iter.next()) |tok| {
                if (tok.kind() == .identifier) return tok.text();
            }
            return "";
        } else if (T == SyntaxElement) {
            if (node_or_token.asToken()) |tok| {
                return tok.text();
            }
            return "";
        } else {
            return node_or_token.text();
        }
    }

    fn firstTokenText(self: *AstBuilder, node: SyntaxNode) []const u8 {
        _ = self;
        var iter = node.childTokens();
        if (iter.next()) |tok| return tok.text();
        return "";
    }

    fn tokenText(self: *AstBuilder, node: SyntaxNode) []const u8 {
        return self.firstTokenText(node);
    }

    fn nodeSpan(self: *AstBuilder, node: SyntaxNode) SourceSpan {
        _ = self;
        return .{
            .file_id = 0,
            .start = node.spanStart(),
            .end = node.spanEnd(),
        };
    }

    fn elementSpan(self: *AstBuilder, elem: SyntaxElement) SourceSpan {
        _ = self;
        return .{
            .file_id = 0,
            .start = elem.spanStart(),
            .end = elem.spanEnd(),
        };
    }
};

const SourceSpan = @import("../source/location/span.zig").SourceSpan;
