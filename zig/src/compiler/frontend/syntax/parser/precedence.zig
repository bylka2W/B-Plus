const token_kind = @import("../token/token_kind.zig");
const TokenKind = token_kind.TokenKind;

pub const Precedence = enum(u8) {
    none = 0,
    assignment = 1,
    range = 2,
    or_ = 3,
    and_ = 4,
    bitwise_or = 5,
    bitwise_xor = 6,
    bitwise_and = 7,
    equality = 8,
    comparison = 9,
    shift = 10,
    additive = 11,
    multiplicative = 12,
    power = 13,
    unary = 14,
    call = 15,
    primary = 16,

    pub fn asU8(self: Precedence) u8 {
        return @intFromEnum(self);
    }

    pub fn higherThan(self: Precedence, other: Precedence) bool {
        return self.asU8() > other.asU8();
    }

    pub fn lowerOrEqual(self: Precedence, other: Precedence) bool {
        return self.asU8() <= other.asU8();
    }
};

pub fn infixPrecedence(kind: TokenKind) ?Precedence {
    return switch (kind) {
        .eq => .assignment,

        .dot_dot, .dot_dot_eq, .dot_dot_dot => .range,

        .pipe_pipe => .or_,

        .amp_amp => .and_,

        .pipe => .bitwise_or,

        .caret => .bitwise_xor,

        .amp => .bitwise_and,

        .eq_eq, .bang_eq => .equality,

        .less, .greater, .less_eq, .greater_eq => .comparison,

        .shl, .shr => .shift,

        .plus, .minus => .additive,

        .star, .slash, .percent => .multiplicative,

        .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .shl_eq, .shr_eq => .assignment,

        else => null,
    };
}

pub fn prefixBindingPower(kind: TokenKind) ?Precedence {
    return switch (kind) {
        .minus, .bang, .tilde, .star, .amp, .kw_ref, .kw_not => .unary,
        else => null,
    };
}

pub fn postfixPrecedence(kind: TokenKind) ?Precedence {
    return switch (kind) {
        .lparen => .call,
        .lbracket => .call,
        .dot => .call,
        .question => .call,
        else => null,
    };
}

pub fn isRightAssociative(kind: TokenKind) bool {
    return switch (kind) {
        .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq,
        .amp_eq, .pipe_eq, .caret_eq, .shl_eq, .shr_eq,
        .caret,
        .dot_dot_eq,
        => true,
        else => false,
    };
}
