const std = @import("std");
const TypeChecker = @import("checker.zig").TypeChecker;
const TypeCheckError = @import("checker.zig").TypeCheckError;
const HirStmtId = @import("checker.zig").HirStmtId;
const HirPatId = @import("checker.zig").HirPatId;
const hir_mod = @import("../hir/arena.zig");
const HirStmt = hir_mod.HirStmt;
const TypeId = @import("../type_system/type_system.zig").TypeId;

pub fn checkStmt(self: *TypeChecker, stmt_id: HirStmtId) TypeCheckError!void {
    const stmt = self.hir.getStmt(stmt_id) orelse return;
    switch (stmt.kind) {
        .local_decl => |ld| try self.checkLocalDecl(ld, stmt.span),
        .expr => |es| {
            _ = try self.checkExpr(es.expr);
        },
        .block => |bs| {
            for (bs.stmts) |sid| {
                try self.checkStmt(sid);
            }
        },
        .if_stmt => |ifs| {
            const cond_ty = try self.checkExpr(ifs.condition);
            _ = self.engine.unify(cond_ty, self.engine.builtin(.bool_type), 0) catch {};
            try self.checkStmt(ifs.then_branch);
            if (ifs.else_branch) |eb| {
                try self.checkStmt(eb);
            }
        },
        .while_stmt => |ws| {
            const cond_ty = try self.checkExpr(ws.condition);
            _ = self.engine.unify(cond_ty, self.engine.builtin(.bool_type), 0) catch {};
            self.pushLoop();
            try self.checkStmt(ws.body);
            self.popLoop();
        },
        .for_stmt => |fs| {
            const iter_ty = try self.checkExpr(fs.iterable);
            self.defineDef(fs.iter_var, iter_ty);
            self.pushLoop();
            try self.checkStmt(fs.body);
            self.popLoop();
        },
        .loop_stmt => |ls| {
            self.pushLoop();
            try self.checkStmt(ls.body);
            self.popLoop();
        },
        .return_stmt => |rs| {
            if (rs.value) |val| {
                const val_ty = try self.checkExpr(val);
                if (self.current_return_type.isValid()) {
                    _ = self.engine.unify(self.current_return_type, val_ty, 0) catch {};
                }
            } else if (self.current_return_type.isValid()) {
                _ = self.engine.unify(self.current_return_type, self.engine.builtin(.void_type), 0) catch {};
            }
        },
        .break_stmt => |bs| {
            if (!self.isInsideLoop()) {
                self.reportError(.{ .break_outside_loop = {} }, stmt.span);
                return;
            }
            if (bs.value) |val| {
                const val_ty = try self.checkExpr(val);
                if (self.currentBreakType()) |break_ty| {
                    _ = self.engine.unify(break_ty, val_ty, 0) catch {};
                }
            }
        },
        .continue_stmt => {
            if (!self.isInsideLoop()) {
                self.reportError(.{ .continue_outside_loop = {} }, stmt.span);
            }
        },
        .defer_stmt => |ds| {
            try self.checkStmt(ds.body);
        },
        .errdefer_stmt => |eds| {
            try self.checkStmt(eds.body);
        },
        .missing => {},
    }
}

fn checkLocalDecl(self: *TypeChecker, ld: anytype, span: anytype) TypeCheckError!void {
    _ = span;
    const init_ty = if (ld.init) |init_expr|
        try self.checkExpr(init_expr)
    else
        self.engine.freshVar();

    if (ld.type_annotation) |ann_ty| {
        const ann = self.hirTypeToTypeId(ann_ty);
        _ = self.engine.unify(ann, init_ty, 0) catch {};
    }

    self.checkPatternAndDefine(ld.pattern, init_ty);
}

fn checkPatternAndDefine(self: *TypeChecker, pat_id: HirPatId, ty: TypeId) void {
    const pat = self.hir.getPattern(pat_id) orelse return;
    switch (pat.kind) {
        .binding => |b| {
            self.defineDef(b.def, ty);
            if (b.sub_pattern.isValid()) {
                self.checkPatternAndDefine(b.sub_pattern, ty);
            }
        },
        .wildcard => {},
        .literal => |lit| {
            const lit_ty = switch (lit.value) {
                .int => self.engine.builtin(.i32_type),
                .float => self.engine.builtin(.f64_type),
                .boolean => self.engine.builtin(.bool_type),
                .string => self.engine.builtin(.str_type),
            };
            _ = self.engine.unify(ty, lit_ty, 0) catch {};
        },
        .tuple => |t| {
            for (t.elements) |elem| {
                self.checkPatternAndDefine(elem, ty);
            }
        },
        else => {},
    }
}
