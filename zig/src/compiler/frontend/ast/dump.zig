const std = @import("std");
const ast_node = @import("ast_node.zig");
const arena_mod = @import("arena.zig");

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
pub const AstArena = arena_mod.AstArena;

pub fn dumpDecl(arena: *const AstArena, id: DeclId, writer: anytype, indent: u32) anyerror!void {
    const decl = arena.getDecl(id) orelse return;
    switch (decl) {
        .fn_decl => |d| {
            try writeIndent(writer, indent);
            try writer.print("FnDecl {s}\n", .{d.name});
            if (d.params.len > 0) {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("Params:\n");
                for (d.params) |p| {
                    try writeIndent(writer, indent + 2);
                    try writer.print("Param {s}", .{p.name});
                    if (p.type_ref) |tr| {
                        try writer.writeAll(" : ");
                        try dumpTypeRef(arena, tr, writer);
                    }
                    try writer.writeAll("\n");
                }
            }
            if (d.return_type) |rt| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("Return: ");
                try dumpTypeRef(arena, rt, writer);
                try writer.writeAll("\n");
            }
            if (d.body) |body| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("Body:\n");
                try dumpStmt(arena, body, writer, indent + 2);
            }
        },
        .struct_decl => |d| {
            try writeIndent(writer, indent);
            try writer.print("StructDecl {s}\n", .{d.name});
            for (d.fields) |f| {
                try writeIndent(writer, indent + 1);
                try writer.print("Field {} : ", .{f.name});
                try dumpTypeRef(arena, f.type_ref, writer);
                try writer.writeAll("\n");
            }
        },
        .enum_decl => |d| {
            try writeIndent(writer, indent);
            try writer.print("EnumDecl {s}\n", .{d.name});
            for (d.variants) |v| {
                try writeIndent(writer, indent + 1);
                try writer.print("Variant {}\n", .{v.name});
            }
        },
        .trait_decl => |d| {
            try writeIndent(writer, indent);
            try writer.print("TraitDecl {s}\n", .{d.name});
        },
        .impl_decl => |d| {
            try writeIndent(writer, indent);
            try writer.writeAll("ImplDecl\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("SelfType: ");
            try dumpTypeRef(arena, d.self_type, writer);
            try writer.writeAll("\n");
        },
        .type_alias => |d| {
            try writeIndent(writer, indent);
            try writer.print("TypeAlias {s} = ", .{d.name});
            try dumpTypeRef(arena, d.target_type, writer);
            try writer.writeAll("\n");
        },
        .import => |d| {
            try writeIndent(writer, indent);
            try writer.print("Import {s}\n", .{d.path});
        },
        .module => |d| {
            try writeIndent(writer, indent);
            try writer.print("Module {s}\n", .{d.name});
        },
        .extern_fn => |d| {
            try writeIndent(writer, indent);
            try writer.print("ExternFn {s}\n", .{d.name});
        },
        .missing => {
            try writeIndent(writer, indent);
            try writer.writeAll("MissingDecl\n");
        },
    }
}

pub fn dumpStmt(arena: *const AstArena, id: StmtId, writer: anytype, indent: u32) anyerror!void {
    const stmt = arena.getStmt(id) orelse return;
    switch (stmt) {
        .let => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Let\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("Pattern: ");
            try dumpPat(arena, s.pattern, writer);
            try writer.writeAll("\n");
            if (s.type_annotation) |ta| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("Type: ");
                try dumpTypeRef(arena, ta, writer);
                try writer.writeAll("\n");
            }
            if (s.init) |i| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("Init: ");
                try dumpExpr(arena, i, writer);
                try writer.writeAll("\n");
            }
        },
        .@"var" => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Var\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("Pattern: ");
            try dumpPat(arena, s.pattern, writer);
            try writer.writeAll("\n");
            if (s.init) |i| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("Init: ");
                try dumpExpr(arena, i, writer);
                try writer.writeAll("\n");
            }
        },
        .const_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Const\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("Pattern: ");
            try dumpPat(arena, s.pattern, writer);
            try writer.writeAll("\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("Init: ");
            try dumpExpr(arena, s.init, writer);
            try writer.writeAll("\n");
        },
        .expr_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("ExprStmt: ");
            try dumpExpr(arena, s.expr, writer);
            try writer.writeAll("\n");
        },
        .block => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Block\n");
            for (s.stmts) |sid| {
                try dumpStmt(arena, sid, writer, indent + 1);
            }
        },
        .if_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("If\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("Cond: ");
            try dumpExpr(arena, s.condition, writer);
            try writer.writeAll("\n");
            try dumpStmt(arena, s.then_block, writer, indent + 1);
            if (s.else_branch) |eb| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("Else:\n");
                try dumpStmt(arena, eb, writer, indent + 2);
            }
        },
        .while_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("While\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("Cond: ");
            try dumpExpr(arena, s.condition, writer);
            try writer.writeAll("\n");
            try dumpStmt(arena, s.body, writer, indent + 1);
        },
        .for_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("For\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("Iterable: ");
            try dumpExpr(arena, s.iterable, writer);
            try writer.writeAll("\n");
            try dumpStmt(arena, s.body, writer, indent + 1);
        },
        .loop_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Loop\n");
            try dumpStmt(arena, s.body, writer, indent + 1);
        },
        .return_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Return");
            if (s.value) |v| {
                try writer.writeAll(": ");
                try dumpExpr(arena, v, writer);
            }
            try writer.writeAll("\n");
        },
        .break_stmt => {
            try writeIndent(writer, indent);
            try writer.writeAll("Break\n");
        },
        .continue_stmt => {
            try writeIndent(writer, indent);
            try writer.writeAll("Continue\n");
        },
        .defer_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Defer\n");
            try dumpStmt(arena, s.body, writer, indent + 1);
        },
        .errdefer_stmt => |s| {
            try writeIndent(writer, indent);
            try writer.writeAll("Errdefer\n");
            try dumpStmt(arena, s.body, writer, indent + 1);
        },
        .missing => {
            try writeIndent(writer, indent);
            try writer.writeAll("MissingStmt\n");
        },
    }
}

pub fn dumpExpr(arena: *const AstArena, id: ExprId, writer: anytype) anyerror!void {
    const expr = arena.getExpr(id) orelse return;
    switch (expr) {
        .literal => |e| {
            try writer.print("Literal({s})", .{@tagName(e.kind)});
        },
        .identifier => |e| {
            try writer.print("Ident({s})", .{e.name});
        },
        .binary => |e| {
            try writer.print("Binary({s}) ", .{@tagName(e.op)});
            try writer.writeAll("[");
            try dumpExpr(arena, e.left, writer);
            try writer.writeAll(", ");
            try dumpExpr(arena, e.right, writer);
            try writer.writeAll("]");
        },
        .unary => |e| {
            try writer.print("Unary({s}) ", .{@tagName(e.op)});
            try writer.writeAll("[");
            try dumpExpr(arena, e.operand, writer);
            try writer.writeAll("]");
        },
        .call => |e| {
            try writer.writeAll("Call[");
            try dumpExpr(arena, e.callee, writer);
            for (e.args) |arg| {
                try writer.writeAll(", ");
                try dumpExpr(arena, arg, writer);
            }
            try writer.writeAll("]");
        },
        .member => |e| {
            try writer.writeAll("Member[");
            try dumpExpr(arena, e.object, writer);
            try writer.print(".{s}]", .{e.member});
        },
        .index => |e| {
            try writer.writeAll("Index[");
            try dumpExpr(arena, e.object, writer);
            try writer.writeAll(", ");
            try dumpExpr(arena, e.index, writer);
            try writer.writeAll("]");
        },
        .paren => |e| {
            try writer.writeAll("Paren[");
            try dumpExpr(arena, e.inner, writer);
            try writer.writeAll("]");
        },
        .if_expr => |e| {
            try writer.writeAll("If[");
            try dumpExpr(arena, e.condition, writer);
            try writer.writeAll(", ");
            try dumpExpr(arena, e.then_block, writer);
            if (e.else_branch) |eb| {
                try writer.writeAll(", else=");
                try dumpExpr(arena, eb, writer);
            }
            try writer.writeAll("]");
        },
        .while_expr => |e| {
            try writer.writeAll("While[");
            try dumpExpr(arena, e.condition, writer);
            try writer.writeAll(", ");
            try dumpExpr(arena, e.body, writer);
            try writer.writeAll("]");
        },
        .for_expr => |e| {
            try writer.writeAll("For[");
            try dumpExpr(arena, e.iterable, writer);
            try writer.writeAll(", ");
            try dumpExpr(arena, e.body, writer);
            try writer.writeAll("]");
        },
        .loop_expr => |e| {
            try writer.writeAll("Loop[");
            try dumpExpr(arena, e.body, writer);
            try writer.writeAll("]");
        },
        .block => |e| {
            try writer.writeAll("Block[\n");
            for (e.stmts) |sid| {
                try dumpStmt(arena, sid, writer, 1);
            }
            try writer.writeAll("]");
        },
        .assign => |e| {
            try writer.writeAll("Assign[");
            try dumpExpr(arena, e.target, writer);
            try writer.writeAll(" = ");
            try dumpExpr(arena, e.value, writer);
            try writer.writeAll("]");
        },
        .return_expr => |e| {
            try writer.writeAll("Return");
            if (e.value) |v| {
                try writer.writeAll("[");
                try dumpExpr(arena, v, writer);
                try writer.writeAll("]");
            }
        },
        .break_expr => {
            try writer.writeAll("Break");
        },
        .continue_expr => {
            try writer.writeAll("Continue");
        },
        .closure => |e| {
            try writer.writeAll("Closure[");
            try dumpExpr(arena, e.body, writer);
            try writer.writeAll("]");
        },
        .match_expr => |e| {
            try writer.writeAll("Match[");
            try dumpExpr(arena, e.scrutinee, writer);
            try writer.print(" with {d} arms]", .{e.arms.len});
        },
        .range => |e| {
            try writer.writeAll("Range[");
            if (e.start) |s| try dumpExpr(arena, s, writer);
            try writer.writeAll("..");
            if (e.end) |en| try dumpExpr(arena, en, writer);
            try writer.writeAll("]");
        },
        .try_expr => |e| {
            try writer.writeAll("Try[");
            try dumpExpr(arena, e.operand, writer);
            try writer.writeAll("]");
        },
        .type_cast => |e| {
            try writer.writeAll("Cast[");
            try dumpExpr(arena, e.operand, writer);
            try writer.writeAll(" as ");
            try dumpTypeRef(arena, e.target_type, writer);
            try writer.writeAll("]");
        },
        .missing => {
            try writer.writeAll("MissingExpr");
        },
    }
}

pub fn dumpTypeRef(arena: *const AstArena, id: TypeRefId, writer: anytype) anyerror!void {
    const tr = arena.getTypeRef(id) orelse return;
    switch (tr) {
        .named => |t| {
            try writer.print("{s}", .{t.name});
        },
        .pointer => |t| {
            try writer.writeAll("*");
            if (t.mutable) try writer.writeAll("mut ");
            try dumpTypeRef(arena, t.pointee, writer);
        },
        .array => |t| {
            try writer.writeAll("[");
            try dumpTypeRef(arena, t.element, writer);
            try writer.writeAll("]");
        },
        .slice => |t| {
            try writer.writeAll("[]");
            try dumpTypeRef(arena, t.element, writer);
        },
        .tuple => |t| {
            try writer.writeAll("(");
            for (t.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(", ");
                try dumpTypeRef(arena, elem, writer);
            }
            try writer.writeAll(")");
        },
        .fn_type => |t| {
            try writer.writeAll("fn(");
            for (t.params, 0..) |param, i| {
                if (i > 0) try writer.writeAll(", ");
                try dumpTypeRef(arena, param, writer);
            }
            try writer.writeAll(") -> ");
            try dumpTypeRef(arena, t.return_type, writer);
        },
        .optional => |t| {
            try writer.writeAll("?");
            try dumpTypeRef(arena, t.inner, writer);
        },
        .missing => {
            try writer.writeAll("MissingType");
        },
    }
}

pub fn dumpPat(arena: *const AstArena, id: PatId, writer: anytype) anyerror!void {
    const pat = arena.getPattern(id) orelse return;
    switch (pat) {
        .identifier => |p| {
            try writer.print("Pat({s})", .{p.name});
        },
        .wildcard => {
            try writer.writeAll("Pat(_)");
        },
        .literal => |p| {
            try writer.writeAll("Pat(");
            try dumpExpr(arena, p.value, writer);
            try writer.writeAll(")");
        },
        .tuple => |p| {
            try writer.writeAll("Pat(");
            for (p.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(", ");
                try dumpPat(arena, elem, writer);
            }
            try writer.writeAll(")");
        },
        .path => |p| {
            try writer.print("Pat({s})", .{p.path});
        },
        .missing => {
            try writer.writeAll("Pat(Missing)");
        },
    }
}

pub fn dumpModule(arena: *const AstArena, decls: []const DeclId, writer: anytype) anyerror!void {
    try writer.writeAll("Module\n");
    for (decls) |did| {
        try dumpDecl(arena, did, writer, 1);
    }
}

fn writeIndent(writer: anytype, indent: u32) !void {
    var i: u32 = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("  ");
    }
}
