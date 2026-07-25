const std = @import("std");
const TypeChecker = @import("checker.zig").TypeChecker;
const TypeCheckError = @import("checker.zig").TypeCheckError;
const HirExprId = @import("checker.zig").HirExprId;
const HirPatId = @import("checker.zig").HirPatId;
const DefId = @import("checker.zig").DefId;
const hir_mod = @import("../hir/arena.zig");
const HirExpr = hir_mod.HirExpr;
const TypeId = @import("../type_system/type_system.zig").TypeId;
const coercion = @import("coercion.zig");

pub fn checkExpr(self: *TypeChecker, expr_id: HirExprId) TypeCheckError!TypeId {
    const expr = self.hir.getExpr(expr_id) orelse return self.engine.freshVar();
    const ty = switch (expr.kind) {
        .literal => |lit| try self.checkLiteral(lit),
        .path => |p| try self.checkPath(p, expr.span),
        .binary => |b| try self.checkBinary(b, expr.span),
        .unary => |u| try self.checkUnary(u, expr.span),
        .block => |b| try self.checkBlockExpr(b),
        .if_expr => |i| try self.checkIfExpr(i),
        .assign => |a| try self.checkAssign(a, expr.span),
        .return_expr => |r| try self.checkReturn(r, expr.span),
        .call => |c| try self.checkCall(c, expr.span),
        .while_expr => |w| try self.checkWhileExpr(w, expr.span),
        .for_expr => |f| try self.checkForExpr(f, expr.span),
        .loop_expr => |l| try self.checkLoopExpr(l, expr.span),
        .break_expr => |b| try self.checkBreakExpr(b, expr.span),
        .continue_expr => try self.checkContinueExpr(expr.span),
        .match_expr => |m| try self.checkMatchExpr(m, expr.span),
        .field => |f| try self.checkField(f, expr.span),
        .index => |i| try self.checkIndex(i, expr.span),
        .closure => |c| try self.checkClosure(c, expr.span),
        .range => |r| try self.checkRange(r, expr.span),
        .type_cast => |tc| try self.checkTypeCast(tc, expr.span),
        .ref => |r| try self.checkRef(r, expr.span),
        .deref => |d| try self.checkDeref(d, expr.span),
        .method_call => |mc| try self.checkMethodCall(mc, expr.span),
        .missing => self.engine.freshVar(),
    };
    self.setExprType(expr_id, ty);
    return ty;
}

fn checkLiteral(self: *TypeChecker, lit: HirExpr.HirExprKind.LiteralExpr) TypeCheckError!TypeId {
    return switch (lit.value) {
        .int => self.engine.builtin(.i32_type),
        .float => self.engine.builtin(.f64_type),
        .boolean => self.engine.builtin(.bool_type),
        .string => self.engine.builtin(.str_type),
    };
}

fn checkPath(self: *TypeChecker, p: HirExpr.HirExprKind.PathExpr, span: anytype) TypeCheckError!TypeId {
    if (self.lookupDef(p.def)) |ty| {
        return ty;
    }
    self.reportError(.{ .undefined_var = .{ .name = "" } }, span);
    return self.engine.freshVar();
}

fn checkBinary(self: *TypeChecker, b: HirExpr.HirExprKind.BinaryExpr, span: anytype) TypeCheckError!TypeId {
    const left_ty = try self.checkExpr(b.left);
    const right_ty = try self.checkExpr(b.right);

    const resolved_l = self.engine.resolve(left_ty);
    const resolved_r = self.engine.resolve(right_ty);

    const left_data = self.engine.get(resolved_l);
    const right_data = self.engine.get(resolved_r);

    if (left_data) |ld| {
        if (right_data) |rd| {
            if (@as(@TypeOf(ld), ld) == .builtin and @as(@TypeOf(rd), rd) == .builtin) {
                if (coercion.canBinOp(b.op, ld.builtin, rd.builtin)) |result_kind| {
                    return self.engine.builtin(result_kind);
                }
                self.reportError(.{ .invalid_binop = .{
                    .op = @tagName(b.op),
                    .left = self.builtinTypeName(resolved_l),
                    .right = self.builtinTypeName(resolved_r),
                } }, span);
                return self.engine.freshVar();
            }
        }
    }

    self.engine.unify(left_ty, right_ty, 0) catch {};
    return left_ty;
}

fn checkUnary(self: *TypeChecker, u: HirExpr.HirExprKind.UnaryExpr, span: anytype) TypeCheckError!TypeId {
    const operand_ty = try self.checkExpr(u.operand);
    const resolved = self.engine.resolve(operand_ty);

    if (self.engine.get(resolved)) |data| {
        if (data == .builtin) {
            if (coercion.canUnaryOp(u.op, data.builtin)) |result_kind| {
                return self.engine.builtin(result_kind);
            }
            self.reportError(.{ .invalid_unop = .{
                .op = @tagName(u.op),
                .operand = self.builtinTypeName(resolved),
            } }, span);
        }
    }
    return operand_ty;
}

fn checkBlockExpr(self: *TypeChecker, b: HirExpr.HirExprKind.BlockExpr) TypeCheckError!TypeId {
    for (b.stmts) |sid| {
        try self.checkStmt(sid);
    }
    if (b.result.isValid()) {
        return self.checkExpr(b.result);
    }
    return self.engine.builtin(.void_type);
}

fn checkIfExpr(self: *TypeChecker, i: HirExpr.HirExprKind.IfExpr) TypeCheckError!TypeId {
    const cond_ty = try self.checkExpr(i.condition);
    _ = self.engine.unify(cond_ty, self.engine.builtin(.bool_type), 0) catch {};
    const then_ty = try self.checkExpr(i.then_branch);
    if (i.else_branch.isValid()) {
        const else_ty = try self.checkExpr(i.else_branch);
        _ = self.engine.unify(then_ty, else_ty, 0) catch {};
        return then_ty;
    }
    return self.engine.builtin(.void_type);
}

fn checkAssign(self: *TypeChecker, a: HirExpr.HirExprKind.AssignExpr, span: anytype) TypeCheckError!TypeId {
    const target_ty = try self.checkExpr(a.target);
    const value_ty = try self.checkExpr(a.value);
    _ = self.engine.unify(target_ty, value_ty, 0) catch {
        self.reportError(.{ .type_mismatch = .{
            .expected = self.builtinTypeName(target_ty),
            .found = self.builtinTypeName(value_ty),
        } }, span);
    };
    return self.engine.builtin(.void_type);
}

fn checkReturn(self: *TypeChecker, r: HirExpr.HirExprKind.ReturnExpr, span: anytype) TypeCheckError!TypeId {
    if (r.value.isValid()) {
        const val_ty = try self.checkExpr(r.value);
        if (self.current_return_type.isValid()) {
            _ = self.engine.unify(self.current_return_type, val_ty, 0) catch {
                self.reportError(.{ .return_type_mismatch = .{
                    .expected = self.builtinTypeName(self.current_return_type),
                    .found = self.builtinTypeName(val_ty),
                } }, span);
            };
        }
    } else if (self.current_return_type.isValid()) {
        _ = self.engine.unify(self.current_return_type, self.engine.builtin(.void_type), 0) catch {};
    }
    return self.engine.builtin(.never_type);
}

fn checkCall(self: *TypeChecker, c: HirExpr.HirExprKind.CallExpr, span: anytype) TypeCheckError!TypeId {
    const callee_ty = try self.checkExpr(c.callee);
    const resolved = self.engine.resolve(callee_ty);
    if (self.engine.get(resolved)) |data| {
        if (data == .fn_ptr) {
            const param_count = data.fn_ptr.params.len;
            const arg_count = c.args.len;
            if (param_count != arg_count) {
                self.reportError(.{ .wrong_arg_count = .{
                    .expected = @intCast(param_count),
                    .found = @intCast(arg_count),
                } }, span);
                return data.fn_ptr.ret;
            }
            for (c.args, 0..) |arg, i| {
                const arg_ty = try self.checkExpr(arg);
                _ = self.engine.unify(data.fn_ptr.params[i], arg_ty, 0) catch {};
            }
            return data.fn_ptr.ret;
        }
    }
    self.reportError(.{ .not_callable = .{} }, span);
    return self.engine.freshVar();
}

fn checkWhileExpr(self: *TypeChecker, w: HirExpr.HirExprKind.WhileExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    const cond_ty = try self.checkExpr(w.condition);
    _ = self.engine.unify(cond_ty, self.engine.builtin(.bool_type), 0) catch {};
    self.pushLoop();
    _ = try self.checkExpr(w.body);
    self.popLoop();
    return self.engine.builtin(.void_type);
}

fn checkForExpr(self: *TypeChecker, f: HirExpr.HirExprKind.ForExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    const iter_ty = try self.checkExpr(f.iterable);
    self.defineDef(f.iter_var, iter_ty);
    self.pushLoop();
    _ = try self.checkExpr(f.body);
    self.popLoop();
    return self.engine.builtin(.void_type);
}

fn checkLoopExpr(self: *TypeChecker, l: HirExpr.HirExprKind.LoopExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    self.pushLoop();
    const body_ty = try self.checkExpr(l.body);
    self.popLoop();
    return body_ty;
}

fn checkBreakExpr(self: *TypeChecker, b: HirExpr.HirExprKind.BreakExpr, span: anytype) TypeCheckError!TypeId {
    if (!self.isInsideLoop()) {
        self.reportError(.{ .break_outside_loop = {} }, span);
        return self.engine.builtin(.never_type);
    }
    if (b.value.isValid()) {
        const val_ty = try self.checkExpr(b.value);
        if (self.currentBreakType()) |break_ty| {
            _ = self.engine.unify(break_ty, val_ty, 0) catch {
                self.reportError(.{ .break_type_mismatch = .{
                    .expected = self.builtinTypeName(break_ty),
                    .found = self.builtinTypeName(val_ty),
                } }, span);
            };
        }
    }
    return self.engine.builtin(.never_type);
}

fn checkContinueExpr(self: *TypeChecker, span: anytype) TypeCheckError!TypeId {
    if (!self.isInsideLoop()) {
        self.reportError(.{ .continue_outside_loop = {} }, span);
    }
    return self.engine.builtin(.never_type);
}

fn checkMatchExpr(self: *TypeChecker, m: HirExpr.HirExprKind.MatchExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    const scrutinee_ty = try self.checkExpr(m.scrutinee);
    const result_ty = self.engine.freshVar();
    for (m.arms) |arm| {
        self.checkPatternAndDefineTy(arm.pattern, scrutinee_ty);
        if (arm.guard.isValid()) {
            const guard_ty = try self.checkExpr(arm.guard);
            _ = self.engine.unify(guard_ty, self.engine.builtin(.bool_type), 0) catch {};
        }
        const arm_ty = try self.checkExpr(arm.body);
        _ = self.engine.unify(result_ty, arm_ty, 0) catch {};
    }
    return result_ty;
}

fn checkPatternAndDefineTy(self: *TypeChecker, pat_id: HirPatId, ty: TypeId) void {
    const pat = self.hir.getPattern(pat_id) orelse return;
    switch (pat.kind) {
        .binding => |b| {
            self.defineDef(b.def, ty);
            if (b.sub_pattern.isValid()) {
                self.checkPatternAndDefineTy(b.sub_pattern, ty);
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
                self.checkPatternAndDefineTy(elem, ty);
            }
        },
        else => {},
    }
}

fn checkField(self: *TypeChecker, f: HirExpr.HirExprKind.FieldExpr, span: anytype) TypeCheckError!TypeId {
    const obj_ty = try self.checkExpr(f.object);
    _ = self.engine.resolve(obj_ty);
    _ = span;
    return self.engine.freshVar();
}

fn checkIndex(self: *TypeChecker, i: HirExpr.HirExprKind.IndexExpr, span: anytype) TypeCheckError!TypeId {
    const obj_ty = try self.checkExpr(i.object);
    const idx_ty = try self.checkExpr(i.index);
    const resolved_idx = self.engine.resolve(idx_ty);
    if (self.engine.get(resolved_idx)) |data| {
        if (data == .builtin) {
            if (!coercion.isIntegral(data.builtin)) {
                self.reportError(.{ .index_not_integer = {} }, span);
            }
        }
    }
    _ = obj_ty;
    return self.engine.freshVar();
}

fn checkClosure(self: *TypeChecker, c: HirExpr.HirExprKind.ClosureExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    var param_types = std.ArrayList(TypeId).init(self.engine.backing_alloc);
    for (c.params) |param| {
        const param_ty = self.hirTypeToTypeId(param.ty);
        self.defineDef(param.def, param_ty);
        param_types.append(param_ty) catch {};
    }
    const body_ty = try self.checkExpr(c.body);
    const ret_ty = if (c.return_type.isValid())
        self.hirTypeToTypeId(c.return_type)
    else
        body_ty;
    return self.engine.type_arena.fnPtr(param_types.items, ret_ty, false);
}

fn checkRange(self: *TypeChecker, r: HirExpr.HirExprKind.RangeExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    const start_ty = try self.checkExpr(r.start);
    if (r.end.isValid()) {
        const end_ty = try self.checkExpr(r.end);
        _ = self.engine.unify(start_ty, end_ty, 0) catch {};
    }
    return start_ty;
}

fn checkTypeCast(self: *TypeChecker, tc: HirExpr.HirExprKind.TypeCastExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    _ = try self.checkExpr(tc.operand);
    return self.hirTypeToTypeId(tc.target_type);
}

fn checkRef(self: *TypeChecker, r: HirExpr.HirExprKind.RefExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    const inner_ty = try self.checkExpr(r.operand);
    return self.engine.type_arena.pointer(
        if (r.mutable) .mut else .@"const",
        inner_ty,
    );
}

fn checkDeref(self: *TypeChecker, d: HirExpr.HirExprKind.DerefExpr, span: anytype) TypeCheckError!TypeId {
    _ = span;
    const inner_ty = try self.checkExpr(d.operand);
    _ = self.engine.resolve(inner_ty);
    return self.engine.freshVar();
}

fn checkMethodCall(self: *TypeChecker, mc: HirExpr.HirExprKind.MethodCallExpr, span: anytype) TypeCheckError!TypeId {
    _ = try self.checkExpr(mc.object);
    for (mc.args) |arg| {
        _ = try self.checkExpr(arg);
    }
    _ = span;
    return self.engine.freshVar();
}
