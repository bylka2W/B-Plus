const std = @import("std");
const Allocator = std.mem.Allocator;
const thir = @import("../middle/thir/thir.zig");
const thir_verify = @import("../middle/thir/verify.zig");
const VerifiedTHIR = @import("verified_thir.zig").VerifiedTHIR;

pub const ThirVerifier = struct {
    allocator: Allocator,
    errors: std.ArrayList(ThirVerifyError),

    pub const ThirVerifyError = union(enum) {
        structural: thir_verify.VerifyError,
        dangling_value_ref: u32,
        dangling_expr_ref: u32,
        misplaced_entry: void,
    };

    pub fn init(allocator: Allocator) ThirVerifier {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(ThirVerifyError).init(allocator),
        };
    }

    pub fn deinit(self: *ThirVerifier) void {
        self.errors.deinit();
    }

    pub fn verify(self: *ThirVerifier, module: *thir.ThirModule) !VerifiedTHIR {
        // Run structural verification (existing verify.zig)
        {
            var ctx = thir_verify.VerifyContext.init(self.allocator, module);
            defer ctx.deinit();
            const ok = try ctx.verify();
            if (!ok) {
                for (ctx.errors.items) |e| {
                    try self.errors.append(.{ .structural = e });
                }
            }
        }

        // Verify value references are in bounds
        for (module.functions.items) |*func| {
            const body = func.body orelse continue;
            for (body.blocks, 0..) |block, bi| {
                for (block.stmts) |stmt| {
                    try self.checkStmtValues(stmt, body.values.len, @intCast(bi));
                }
                try self.checkTerminatorValues(block.terminator, body.values.len);
            }
            for (body.exprs) |expr| {
                try self.checkExprValues(expr, body.values.len);
            }
        }

        if (self.errors.items.len > 0) {
            return error.VerificationFailed;
        }

        return VerifiedTHIR{ .module = module };
    }

    fn checkStmtValues(_: *ThirVerifier, stmt: thir.ThirStmt, value_count: usize, _: u32) !void {
        switch (stmt.kind) {
            .let => |l| {
                if (l.place.index >= value_count) return error.VerificationFailed;
                if (l.init.index >= value_count) return error.VerificationFailed;
            },
            .assignment => |a| {
                if (a.place.index >= value_count) return error.VerificationFailed;
                if (a.value.index >= value_count) return error.VerificationFailed;
            },
            .expr_stmt => |e| {
                if (e.expr.index >= value_count) return error.VerificationFailed;
            },
            .return_stmt => |r| {
                if (r.value) |v| {
                    if (v.index >= value_count) return error.VerificationFailed;
                }
            },
            .break_stmt => |b| {
                if (b.value) |v| {
                    if (v.index >= value_count) return error.VerificationFailed;
                }
            },
            else => {},
        }
    }

    fn checkTerminatorValues(_: *ThirVerifier, term: thir.BasicBlock.Terminator, value_count: usize) !void {
        switch (term) {
            .cond_br => |cb| {
                if (cb.cond.index >= value_count) return error.VerificationFailed;
            },
            .switch_br => |sw| {
                if (sw.scrutinee.index >= value_count) return error.VerificationFailed;
            },
            .return_ret => |r| {
                if (r.value) |v| {
                    if (v.index >= value_count) return error.VerificationFailed;
                }
            },
            else => {},
        }
    }

    fn checkExprValues(_: *ThirVerifier, expr: thir.ThirExpr, value_count: usize) !void {
        switch (expr.kind) {
            .load => |l| {
                if (l.place.local.index >= value_count) return error.VerificationFailed;
            },
            .store => |s| {
                if (s.place.local.index >= value_count) return error.VerificationFailed;
                if (s.value.index >= value_count) return error.VerificationFailed;
            },
            .binary => |b| {
                if (b.lhs.index >= value_count) return error.VerificationFailed;
                if (b.rhs.index >= value_count) return error.VerificationFailed;
            },
            .unary => |u| {
                if (u.operand.index >= value_count) return error.VerificationFailed;
            },
            .cast => |c| {
                if (c.operand.index >= value_count) return error.VerificationFailed;
            },
            .call => |c| {
                for (c.args) |arg| {
                    if (arg.index >= value_count) return error.VerificationFailed;
                }
            },
            .field_addr => |f| {
                if (f.object.index >= value_count) return error.VerificationFailed;
            },
            .index_addr => |i| {
                if (i.object.index >= value_count) return error.VerificationFailed;
                if (i.index.index >= value_count) return error.VerificationFailed;
            },
            .aggregate => |a| {
                for (a.fields) |f| {
                    if (f.index >= value_count) return error.VerificationFailed;
                }
            },
            .array_repeat => |a| {
                if (a.value.index >= value_count) return error.VerificationFailed;
            },
            .addr_of => |a| {
                if (a.operand.index >= value_count) return error.VerificationFailed;
            },
            .deref => |d| {
                if (d.operand.index >= value_count) return error.VerificationFailed;
            },
            .switch_expr => |s| {
                if (s.scrutinee.index >= value_count) return error.VerificationFailed;
            },
            .return_val => |r| {
                if (r.value) |v| {
                    if (v.index >= value_count) return error.VerificationFailed;
                }
            },
            .break_val => |b| {
                if (b.value) |v| {
                    if (v.index >= value_count) return error.VerificationFailed;
                }
            },
            else => {},
        }
    }
};
