const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const StmtId = @import("../lower.zig").StmtId;
const LocalKind = @import("../lower.zig").LocalKind;
const UNK = @import("../lower.zig").UNK;

pub fn lowerLocalDecl(self: *HirLowering, ast_sid: @import("../lower.zig").AstStmtId) LowerError!StmtId {
    const ast_stmt = self.ast.getStmt(ast_sid) orelse return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 });
    switch (ast_stmt) {
        .let => |l| {
            const pat = try self.lowerPattern(l.pattern);
            const type_ann = if (l.type_annotation) |ta| try self.lowerTypeRefId(ta) else UNK;
            const init = if (l.init) |i| try self.lowerExpr(i) else null;
            return self.localDecl(.let, pat, type_ann, init, l.span);
        },
        .@"var" => |v| {
            const pat = try self.lowerPattern(v.pattern);
            const type_ann = if (v.type_annotation) |ta| try self.lowerTypeRefId(ta) else UNK;
            const init = if (v.init) |i| try self.lowerExpr(i) else null;
            return self.localDecl(.@"var", pat, type_ann, init, v.span);
        },
        .const_stmt => |c| {
            const pat = try self.lowerPattern(c.pattern);
            const type_ann = if (c.type_annotation) |ta| try self.lowerTypeRefId(ta) else UNK;
            const init = try self.lowerExpr(c.init);
            return self.localDecl(.const_val, pat, type_ann, init, c.span);
        },
        else => return self.missingStmt(.{ .file_id = 0, .start = 0, .end = 0 }),
    }
}
