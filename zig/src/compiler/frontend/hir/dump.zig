const std = @import("std");
const arena_mod = @import("arena.zig");
const HirArena = arena_mod.HirArena;

pub fn dumpHIR(arena: *const HirArena, writer: anytype) !void {
    var i: u32 = 0;
    while (i < arena.itemCount()) : (i += 1) {
        const item_id = arena_mod.ItemId.new(i);
        const item = arena.getItem(item_id) orelse continue;
        try dumpItem(arena, item, writer, 0);
    }
}

fn dumpItem(_: *const HirArena, item: arena_mod.HirItem, writer: anytype, indent: u32) !void {
    const pad = "  " ** 32;
    switch (item.kind) {
        .fn_decl => |f| {
            try writer.print("{s}fn {d}(", .{ pad[0..indent * 2], f.name.index });
            for (f.params, 0..) |p, idx| {
                if (idx > 0) try writer.print(", ", .{});
                try writer.print("{d}: type({d})", .{ p.name.index, p.ty.index });
            }
            try writer.print(") type({d})\n", .{f.return_type.index});
        },
        .struct_item => |s| {
            try writer.print("{s}struct {d}\n", .{ pad[0..indent * 2], s.name.index });
            for (s.fields) |f| {
                try writer.print("{s}  field {d}: type({d})\n", .{ pad[0..indent * 2], f.name.index, f.ty.index });
            }
        },
        .enum_item => |e| {
            try writer.print("{s}enum {d}\n", .{ pad[0..indent * 2], e.name.index });
            for (e.variants) |v| {
                try writer.print("{s}  variant {d}\n", .{ pad[0..indent * 2], v.name.index });
            }
        },
        .const_item => |c| {
            try writer.print("{s}const {d}: type({d})\n", .{ pad[0..indent * 2], c.name.index, c.ty.index });
        },
        .trait_item => |t| {
            try writer.print("{s}trait {d}\n", .{ pad[0..indent * 2], t.name.index });
        },
        .impl_item => |_| {
            try writer.print("{s}impl\n", .{pad[0..indent * 2]});
        },
        .type_alias => |ta| {
            try writer.print("{s}type {d} = type({d})\n", .{ pad[0..indent * 2], ta.name.index, ta.target.index });
        },
        .extern_fn => |ef| {
            try writer.print("{s}extern fn {d}()\n", .{ pad[0..indent * 2], ef.name.index });
        },
        .state_item => |st| {
            try writer.print("{s}state {d}\n", .{ pad[0..indent * 2], st.name.index });
            for (st.fields) |v| {
                try writer.print("{s}  field {d}: type({d})\n", .{ pad[0..indent * 2], v.name.index, v.ty.index });
            }
            if (st.entry) |b| {
                try writer.print("{s}  entry: BodyId({d})\n", .{ pad[0..indent * 2], b.index });
            }
            if (st.exit) |b| {
                try writer.print("{s}  exit: BodyId({d})\n", .{ pad[0..indent * 2], b.index });
            }
            for (st.transitions) |tr| {
                try writer.print("{s}  -> DefId({d})\n", .{ pad[0..indent * 2], tr.target.index });
            }
        },
        .kernel_item => |k| {
            try writer.print("{s}kernel {d}\n", .{ pad[0..indent * 2], k.name.index });
            try writer.print("{s}  dispatch ({d},{d},{d})\n", .{ pad[0..indent * 2], k.dispatch.x, k.dispatch.y, k.dispatch.z });
            for (k.entries) |e| {
                try writer.print("{s}  entry {d}()\n", .{ pad[0..indent * 2], e.name.index });
            }
            for (k.bindings) |b| {
                try writer.print("{s}  binding {d} slot={d}\n", .{ pad[0..indent * 2], b.name.index, b.slot });
            }
        },
        .missing => {
            try writer.print("{s}<<missing>>\n", .{pad[0..indent * 2]});
        },
    }
}

pub fn dumpExpr(arena: *const HirArena, expr_id: arena_mod.ExprId, writer: anytype) !void {
    const expr_val = arena.getExpr(expr_id) orelse return;
    try writer.print("Expr #{d} {s}\n", .{ expr_id.index, @tagName(expr_val.kind) });
    switch (expr_val.kind) {
        .literal => |l| try writer.print("  value={}\n", .{l.value}),
        .path => |p| try writer.print("  def=DefId({d})\n", .{p.def.index}),
        .binary => |b| {
            try writer.print("  op={s}\n", .{@tagName(b.op)});
            try writer.print("  left=ExprId({d})\n", .{b.left.index});
            try writer.print("  right=ExprId({d})\n", .{b.right.index});
        },
        .unary => |u| {
            try writer.print("  op={s}\n", .{@tagName(u.op)});
            try writer.print("  operand=ExprId({d})\n", .{u.operand.index});
        },
        .call => |c| {
            try writer.print("  callee=ExprId({d})\n", .{c.callee.index});
            try writer.print("  args={d}\n", .{c.args.len});
        },
        .block => |b| {
            try writer.print("  stmts={d}\n", .{b.stmts.len});
            try writer.print("  result=ExprId({d})\n", .{b.result.index});
        },
        .if_expr => |i| {
            try writer.print("  cond=ExprId({d})\n", .{i.condition.index});
            try writer.print("  then=ExprId({d})\n", .{i.then_branch.index});
            try writer.print("  else=ExprId({d})\n", .{i.else_branch.index});
        },
        .assign => |a| {
            try writer.print("  target=ExprId({d})\n", .{a.target.index});
            try writer.print("  value=ExprId({d})\n", .{a.value.index});
        },
        .missing => try writer.print("  <<missing>>\n", .{}),
        else => {},
    }
}

pub fn dumpStmt(arena: *const HirArena, stmt_id: arena_mod.StmtId, writer: anytype) !void {
    const stmt_val = arena.getStmt(stmt_id) orelse return;
    try writer.print("Stmt #{d} {s}\n", .{ stmt_id.index, @tagName(stmt_val.kind) });
    switch (stmt_val.kind) {
        .local_decl => |l| {
            try writer.print("  kind={s}\n", .{@tagName(l.kind)});
            try writer.print("  pat=PatId({d})\n", .{l.pattern.index});
            if (l.type_annotation.isValid()) try writer.print("  ty=TypeId({d})\n", .{l.type_annotation.index});
            if (l.init.isValid()) try writer.print("  init=ExprId({d})\n", .{l.init.index});
        },
        .expr => |e| try writer.print("  expr=ExprId({d})\n", .{e.expr.index}),
        .block => |b| try writer.print("  stmts={d}\n", .{b.stmts.len}),
        .missing => try writer.print("  <<missing>>\n", .{}),
        else => {},
    }
}

pub fn dumpPattern(arena: *const HirArena, pat_id: arena_mod.PatId, writer: anytype) !void {
    const pat_val = arena.getPattern(pat_id) orelse return;
    try writer.print("Pat #{d} {s}\n", .{ pat_id.index, @tagName(pat_val.kind) });
    switch (pat_val.kind) {
        .binding => |b| {
            try writer.print("  def=DefId({d})\n", .{b.def.index});
            try writer.print("  sub=PatId({d})\n", .{b.sub_pattern.index});
            try writer.print("  mutable={s}\n", .{if (b.mutable) "true" else "false"});
        },
        .wildcard => try writer.print("  _\n", .{}),
        .literal => |l| try writer.print("  value={}\n", .{l.value}),
        .tuple => |t| try writer.print("  elements={d}\n", .{t.elements.len}),
        .struct_pat => |s| {
            try writer.print("  def=DefId({d})\n", .{s.def.index});
            try writer.print("  fields={d}\n", .{s.fields.len});
        },
        .range => |r| {
            try writer.print("  start={}\n", .{r.start});
            try writer.print("  end={}\n", .{r.end});
            try writer.print("  inclusive={s}\n", .{if (r.inclusive) "true" else "false"});
        },
        .missing => try writer.print("  <<missing>>\n", .{}),
    }
}
