const std = @import("std");
const HirLowering = @import("lower.zig").HirLowering;
const LowerError = @import("lower.zig").LowerError;
const PatId = @import("lower.zig").PatId;
const DefId = @import("lower.zig").DefId;
const SymbolId = @import("lower.zig").SymbolId;
const AstPatId = @import("lower.zig").AstPatId;
const AstPattern = @import("lower.zig").AstPattern;
const HirLiteral = @import("../literal.zig").HirLiteral;
const UNK = @import("lower.zig").UNK;

pub fn lowerPattern(self: *HirLowering, ast_pat_id: AstPatId) LowerError!PatId {
    if (!ast_pat_id.isValid()) return self.patternWildcard(.{ .file_id = 0, .start = 0, .end = 0 });
    const ast_pat = self.ast.getPattern(ast_pat_id) orelse return self.patternWildcard(.{ .file_id = 0, .start = 0, .end = 0 });
    return self.lowerPatternNode(ast_pat);
}

pub fn lowerPatternNode(self: *HirLowering, ast_pat: AstPattern) LowerError!PatId {
    return switch (ast_pat) {
        .identifier => |i| {
            const def = self.lookupDef(i.name);
            return self.patternIdentifier(def, UNK, i.mutable, i.span);
        },
        .wildcard => |w| self.patternWildcard(w.span),
        .literal => |l| {
            const lit_val: HirLiteral = .{ .int = 0 };
            return self.patternLiteral(lit_val, UNK, l.span);
        },
        .tuple => |t| {
            const elements = try self.lowerPatternSlice(t.elements);
            return self.patternTuple(elements, UNK, t.span);
        },
        .path => |p| {
            const def = self.lookupDef(p.path);
            return self.patternIdentifier(def, UNK, false, p.span);
        },
        .missing => |m| self.patternWildcard(m.span),
    };
}

pub fn resolveName(self: *HirLowering, name: SymbolId) DefId {
    return self.lookupDef(name);
}
