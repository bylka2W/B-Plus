const std = @import("std");
const thir = @import("thir.zig");

pub fn dumpModule(module: *thir.ThirModule, writer: anytype) !void {
    try writer.print("=== THIR Module ===\n\n", .{});

    for (module.structs.items) |s| {
        try writer.print("struct %{d} {{\n", .{s.name.index});
        for (s.fields) |f| {
            try writer.print("  %{d}: type(%{d}),\n", .{ f.name.index, f.ty.index });
        }
        try writer.print("}}\n\n", .{});
    }

    for (module.enums.items) |e| {
        try writer.print("enum %{d} {{\n", .{e.name.index});
        for (e.variants) |v| {
            try writer.print("  %{d} (tag={d}) {{\n", .{ v.name.index, v.tag });
            for (v.fields) |f| {
                try writer.print("    %{d}: type(%{d}),\n", .{ f.name.index, f.ty.index });
            }
            try writer.print("  }}\n", .{});
        }
        try writer.print("}}\n\n", .{});
    }

    for (module.functions.items) |func| {
        try writer.print("fn %{d}(", .{func.name.index});
        for (func.params, 0..) |p, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("p%{d}: type(%{d})", .{ p.def_id.index, p.ty.index });
        }
        try writer.print(") -> type(%{d})", .{func.return_type.index});

        if (func.linkage == .@"export") try writer.print(" @export", .{});
        try writer.print(" {{\n", .{});

        if (func.body) |body| {
            for (body.blocks, 0..) |block, i| {
                try writer.print("\nblock{d} ({s}):\n", .{ i, block.label });
                for (block.stmts) |stmt| {
                    try writer.print("  ", .{});
                    try dumpStmt(stmt, writer);
                }
                try writer.print("  ", .{});
                try dumpTerminator(block.terminator, writer);
            }
        } else {
            try writer.print("  (no body)\n", .{});
        }

        try writer.print("}}\n\n", .{});
    }
}

fn dumpStmt(stmt: thir.ThirStmt, writer: anytype) !void {
    switch (stmt.kind) {
        .let => |l| {
            try writer.print("%{d} = %{d};\n", .{ l.place.index, l.init.index });
        },
        .assignment => |a| {
            try writer.print("%{d} = %{d};\n", .{ a.place.index, a.value.index });
        },
        .expr_stmt => |e| {
            try writer.print("expr %{};\n", .{e.expr.index});
        },
        .if_stmt => |i| {
            try writer.print("if %{d} goto block{d} else block{d};\n", .{
                i.cond.index,
                i.then_block.index,
                if (i.else_block) |eb| eb.index else i.then_block.index,
            });
        },
        .while_stmt => |w| {
            try writer.print("while loop: cond=block{d} body=block{d} exit=block{d};\n", .{
                w.cond_block.index,
                w.body_block.index,
                w.exit_block.index,
            });
        },
        .return_stmt => |r| {
            if (r.value) |v| {
                try writer.print("return %{};\n", .{v.index});
            } else {
                try writer.print("return;\n", .{});
            }
        },
        .break_stmt => |b| {
            if (b.value) |v| {
                try writer.print("break %{} to block{d};\n", .{ v.index, b.target_loop.index });
            } else {
                try writer.print("break to block{d};\n", .{b.target_loop.index});
            }
        },
        .continue_stmt => |c| {
            try writer.print("continue to block{d};\n", .{c.target_loop.index});
        },
        .block => |blk| {
            try writer.print("goto block{d};\n", .{blk.block.index});
        },
    }
}

fn dumpTerminator(term: thir.BasicBlock.Terminator, writer: anytype) !void {
    switch (term) {
        .br => |t| {
            try writer.print("br block{d};\n", .{t.index});
        },
        .cond_br => |cb| {
            try writer.print("br %{d} ? block{d} : block{d};\n", .{
                cb.cond.index,
                cb.then.index,
                cb.else_.index,
            });
        },
        .switch_br => |sw| {
            try writer.print("switch %{d} {{\n", .{sw.scrutinee.index});
            for (sw.cases) |c| {
                try writer.print("  case {d} -> block{d};\n", .{ c.value, c.target.index });
            }
            if (sw.default) |d| {
                try writer.print("  default -> block{d};\n", .{d.index});
            }
            try writer.print("}}\n", .{});
        },
        .return_ret => |r| {
            if (r.value) |v| {
                try writer.print("return %{};\n", .{v.index});
            } else {
                try writer.print("return;\n", .{});
            }
        },
        .unreachable_term => {
            try writer.print("unreachable;\n", .{});
        },
        .diverge => {
            try writer.print("(diverge)\n", .{});
        },
    }
}
