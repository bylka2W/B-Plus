const std = @import("std");
const events_mod = @import("events.zig");
const precedence_mod = @import("precedence.zig");
const token_kind = @import("../token/token_kind.zig");
const keyword_mod = @import("../token/keyword.zig");
const kind_mod = @import("../kind/syntax_kind.zig");
const tokenKindToSyntaxKind = kind_mod.tokenKindToSyntaxKind;

pub const TokenKind = token_kind.TokenKind;
pub const EventSink = events_mod.EventSink;
pub const SyntaxKind = events_mod.SyntaxKind;
pub const Precedence = precedence_mod.Precedence;

pub const ExpressionParser = struct {
    events: *EventSink,

    pub fn init(events: *EventSink) ExpressionParser {
        return .{ .events = events };
    }

    pub fn parseExpression(self: *ExpressionParser, stream: anytype) void {
        self.parseExpressionPrec(stream, .none);
    }

    fn parseExpressionPrec(self: *ExpressionParser, stream: anytype, min_bp: Precedence) void {
        const checkpoint: u32 = @intCast(self.events.events.items.len);
        self.parsePrefix(stream);

        while (true) {
            const before = stream.positionAsU32();
            const tok = stream.current();
            const kind = tok.kind;

            if (kind == .eof) break;

            if (kind == .semicolon or kind == .rbrace or kind == .rparen or
                kind == .rbracket or kind == .comma or kind == .kw_else)
            {
                break;
            }

            if (precedence_mod.postfixPrecedence(kind)) |post_bp| {
                if (post_bp.lowerOrEqual(min_bp)) break;
                self.parsePostfix(stream, kind);
                if (!stream.recoverProgress(before)) continue;
                continue;
            }

            if (kind == .arrow) {
                if (Precedence.assignment.lowerOrEqual(min_bp)) break;
                self.events.insertStartNode(.binary_expr, checkpoint);
                self.eatToken(stream);
                self.parseExpressionPrec(stream, .assignment);
                self.events.finishNode();
                if (!stream.recoverProgress(before)) continue;
                continue;
            }

            if (precedence_mod.infixPrecedence(kind)) |bp| {
                if (bp.lowerOrEqual(min_bp)) break;
                const is_right = precedence_mod.isRightAssociative(kind);
                const next_min = if (is_right) @as(Precedence, @enumFromInt(bp.asU8() - 1)) else bp;

                self.events.insertStartNode(.binary_expr, checkpoint);
                self.eatToken(stream);
                self.parseExpressionPrec(stream, next_min);
                self.events.finishNode();
                if (!stream.recoverProgress(before)) continue;
                continue;
            }

            break;
        }
    }

    fn parsePrefix(self: *ExpressionParser, stream: anytype) void {
        const kind = stream.current().kind;

        if (kind == .minus or kind == .bang or kind == .tilde or kind == .star or kind == .amp) {
            _ = self.events.startNode(.unary_expr);
            self.eatToken(stream);
            self.parseExpressionPrec(stream, .unary);
            self.events.finishNode();
            return;
        }

        if (kind == .kw_ref) {
            _ = self.events.startNode(.unary_expr);
            self.eatToken(stream);
            self.parseExpressionPrec(stream, .unary);
            self.events.finishNode();
            return;
        }

        if (kind == .kw_return) {
            _ = self.events.startNode(.return_expr);
            self.eatToken(stream);
            if (!stream.at(.semicolon) and !stream.at(.rbrace) and !stream.at(.eof)) {
                self.parseExpression(stream);
            }
            self.events.finishNode();
            return;
        }

        if (kind == .kw_break) {
            _ = self.events.startNode(.break_expr);
            self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (kind == .kw_continue) {
            _ = self.events.startNode(.continue_expr);
            self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (kind == .kw_if) {
            self.parseIfExpr(stream);
            return;
        }

        if (kind == .kw_while) {
            self.parseWhileExpr(stream);
            return;
        }

        if (kind == .kw_loop) {
            self.parseLoopExpr(stream);
            return;
        }

        if (kind == .kw_for) {
            self.parseForExpr(stream);
            return;
        }

        if (kind == .lbrace) {
            self.parseBlockExpr(stream);
            return;
        }

        if (kind == .lparen) {
            _ = self.events.startNode(.paren_expr);
            self.eatToken(stream);
            if (!stream.at(.rparen)) {
                self.parseExpression(stream);
            }
            if (stream.at(.rparen)) self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        self.parseAtom(stream);
    }

    fn parseAtom(self: *ExpressionParser, stream: anytype) void {
        const kind = stream.current().kind;

        if (kind == .int_literal or kind == .float_literal or kind == .string_literal or
            kind == .char_literal or kind == .byte_literal or kind == .byte_string_literal or
            kind == .true_literal or kind == .false_literal or kind == .null_literal or
            kind == .kw_true or kind == .kw_false or kind == .kw_null)
        {
            _ = self.events.startNode(.literal_expr);
            self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (kind == .identifier) {
            _ = self.events.startNode(.identifier_expr);
            self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (kind == .kw_fn) {
            self.parseClosureExpr(stream);
            return;
        }

        _ = self.events.startNode(.literal_expr);
        self.events.finishNode();
    }

    fn parsePostfix(self: *ExpressionParser, stream: anytype, kind: TokenKind) void {
        switch (kind) {
            .lparen => {
                _ = self.events.startNode(.call_expr);
                self.eatToken(stream);
                while (!stream.at(.rparen) and !stream.at(.eof)) {
                    const before = stream.positionAsU32();
                    self.parseExpression(stream);
                    if (stream.at(.comma)) self.eatToken(stream);
                    _ = stream.recoverProgress(before);
                }
                if (stream.at(.rparen)) self.eatToken(stream);
                self.events.finishNode();
            },
            .lbracket => {
                _ = self.events.startNode(.index_expr);
                self.eatToken(stream);
                self.parseExpression(stream);
                if (stream.at(.rbracket)) self.eatToken(stream);
                self.events.finishNode();
            },
            .dot => {
                _ = self.events.startNode(.member_expr);
                self.eatToken(stream);
                if (stream.at(.identifier)) self.eatToken(stream);
                self.events.finishNode();
            },
            .question => {
                _ = self.events.startNode(.try_expr);
                self.eatToken(stream);
                self.events.finishNode();
            },
            else => {},
        }
    }

    fn parseIfExpr(self: *ExpressionParser, stream: anytype) void {
        _ = self.events.startNode(.if_expr);
        self.eatToken(stream);
        self.parseExpression(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockExpr(stream);
        }
        if (stream.at(.kw_else)) {
            self.eatToken(stream);
            if (stream.at(.kw_if)) {
                self.parseIfExpr(stream);
            } else if (stream.at(.lbrace)) {
                self.parseBlockExpr(stream);
            }
        }
        self.events.finishNode();
    }

    fn parseWhileExpr(self: *ExpressionParser, stream: anytype) void {
        _ = self.events.startNode(.while_expr);
        self.eatToken(stream);
        self.parseExpression(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockExpr(stream);
        }
        self.events.finishNode();
    }

    fn parseLoopExpr(self: *ExpressionParser, stream: anytype) void {
        _ = self.events.startNode(.loop_expr);
        self.eatToken(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockExpr(stream);
        }
        self.events.finishNode();
    }

    fn parseForExpr(self: *ExpressionParser, stream: anytype) void {
        _ = self.events.startNode(.for_expr);
        self.eatToken(stream);
        if (stream.at(.identifier)) self.eatToken(stream);
        if (stream.at(.kw_in)) self.eatToken(stream);
        self.parseExpression(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockExpr(stream);
        }
        self.events.finishNode();
    }

    fn parseBlockExpr(self: *ExpressionParser, stream: anytype) void {
        _ = self.events.startNode(.block_expr);
        self.eatToken(stream);
        while (!stream.at(.rbrace) and !stream.at(.eof)) {
            const before = stream.positionAsU32();
            self.parseExpression(stream);
            if (stream.at(.semicolon)) self.eatToken(stream);
            _ = stream.recoverProgress(before);
        }
        if (stream.at(.rbrace)) self.eatToken(stream);
        self.events.finishNode();
    }

    fn parseClosureExpr(self: *ExpressionParser, stream: anytype) void {
        _ = self.events.startNode(.closure_expr);
        self.eatToken(stream);
        while (!stream.at(.pipe) and !stream.at(.eof)) {
            const before = stream.positionAsU32();
            if (stream.at(.identifier)) self.eatToken(stream);
            if (stream.at(.comma)) self.eatToken(stream);
            _ = stream.recoverProgress(before);
        }
        if (stream.at(.pipe)) self.eatToken(stream);
        if (stream.at(.arrow)) {
            self.eatToken(stream);
            _ = self.events.startNode(.type_ref);
            self.eatToken(stream);
            self.events.finishNode();
        }
        if (stream.at(.lbrace)) {
            self.parseBlockExpr(stream);
        }
        self.events.finishNode();
    }

    fn eatToken(self: *ExpressionParser, stream: anytype) void {
        const tok = stream.current();
        self.events.addToken(tokenKindToSyntaxKind(tok.kind), tok.text, tok.span.start, tok.span.end);
        _ = stream.advance();
        stream.skipTrivia();
    }
};
