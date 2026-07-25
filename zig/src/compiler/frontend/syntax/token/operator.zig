const token_kind = @import("token_kind.zig");
const TokenKind = token_kind.TokenKind;

pub const OpCategory = enum {
    arithmetic,
    comparison,
    logical,
    bitwise,
    assignment,
    compound_assignment,
    range,
    pointer,
    other,
};

pub const OperatorInfo = struct {
    kind: TokenKind,
    category: OpCategory,
    precedence: u8,
    associativity: Associativity,

    pub const Associativity = enum { left, right, none };
};

pub const operators = [_]OperatorInfo{
    .{ .kind = .plus, .category = .arithmetic, .precedence = 11, .associativity = .left },
    .{ .kind = .minus, .category = .arithmetic, .precedence = 11, .associativity = .left },
    .{ .kind = .star, .category = .arithmetic, .precedence = 12, .associativity = .left },
    .{ .kind = .slash, .category = .arithmetic, .precedence = 12, .associativity = .left },
    .{ .kind = .percent, .category = .arithmetic, .precedence = 12, .associativity = .left },
    .{ .kind = .caret, .category = .arithmetic, .precedence = 13, .associativity = .right },

    .{ .kind = .eq_eq, .category = .comparison, .precedence = 8, .associativity = .left },
    .{ .kind = .bang_eq, .category = .comparison, .precedence = 8, .associativity = .left },
    .{ .kind = .less, .category = .comparison, .precedence = 9, .associativity = .left },
    .{ .kind = .greater, .category = .comparison, .precedence = 9, .associativity = .left },
    .{ .kind = .less_eq, .category = .comparison, .precedence = 9, .associativity = .left },
    .{ .kind = .greater_eq, .category = .comparison, .precedence = 9, .associativity = .left },

    .{ .kind = .amp_amp, .category = .logical, .precedence = 4, .associativity = .left },
    .{ .kind = .pipe_pipe, .category = .logical, .precedence = 3, .associativity = .left },
    .{ .kind = .bang, .category = .logical, .precedence = 14, .associativity = .right },

    .{ .kind = .amp, .category = .bitwise, .precedence = 7, .associativity = .left },
    .{ .kind = .pipe, .category = .bitwise, .precedence = 6, .associativity = .left },
    .{ .kind = .caret, .category = .bitwise, .precedence = 5, .associativity = .left },
    .{ .kind = .tilde, .category = .bitwise, .precedence = 14, .associativity = .right },
    .{ .kind = .shl, .category = .bitwise, .precedence = 10, .associativity = .left },
    .{ .kind = .shr, .category = .bitwise, .precedence = 10, .associativity = .left },

    .{ .kind = .eq, .category = .assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .plus_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .minus_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .star_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .slash_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .percent_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .amp_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .pipe_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .caret_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .shl_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },
    .{ .kind = .shr_eq, .category = .compound_assignment, .precedence = 2, .associativity = .right },

    .{ .kind = .dot_dot, .category = .range, .precedence = 5, .associativity = .left },
    .{ .kind = .dot_dot_eq, .category = .range, .precedence = 5, .associativity = .left },
    .{ .kind = .dot_dot_dot, .category = .range, .precedence = 5, .associativity = .left },

    .{ .kind = .star, .category = .pointer, .precedence = 14, .associativity = .right },
    .{ .kind = .amp, .category = .pointer, .precedence = 14, .associativity = .right },
};

pub fn getOperatorInfo(kind: TokenKind) ?OperatorInfo {
    for (operators) |op| {
        if (op.kind == kind) return op;
    }
    return null;
}

pub fn getPrecedence(kind: TokenKind) u8 {
    if (getOperatorInfo(kind)) |op| return op.precedence;
    return 0;
}

pub fn isBinaryOperator(kind: TokenKind) bool {
    return getOperatorInfo(kind) != null and kind != .bang and kind != .tilde;
}

pub fn isAssignmentOperator(kind: TokenKind) bool {
    const info = getOperatorInfo(kind) orelse return false;
    return info.category == .assignment or info.category == .compound_assignment;
}

pub fn isPrefixOperator(kind: TokenKind) bool {
    return switch (kind) {
        .bang, .minus, .star, .amp, .tilde, .kw_ref, .kw_not => true,
        else => false,
    };
}
