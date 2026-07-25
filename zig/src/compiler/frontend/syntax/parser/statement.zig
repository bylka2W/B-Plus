const std = @import("std");
const events_mod = @import("events.zig");
const expression_mod = @import("expression.zig");
const pattern_mod = @import("pattern.zig");
const token_kind = @import("../token/token_kind.zig");
const kind_mod = @import("../kind/syntax_kind.zig");
const tokenKindToSyntaxKind = kind_mod.tokenKindToSyntaxKind;

pub const TokenKind = token_kind.TokenKind;
pub const EventSink = events_mod.EventSink;
pub const SyntaxKind = events_mod.SyntaxKind;
pub const ExpressionParser = expression_mod.ExpressionParser;
pub const PatternParser = pattern_mod.PatternParser;

pub const StatementParser = struct {
    events: *EventSink,
    expr_parser: ExpressionParser,
    pat_parser: PatternParser,

    pub fn init(events: *EventSink) StatementParser {
        return .{
            .events = events,
            .expr_parser = ExpressionParser.init(events),
            .pat_parser = PatternParser.init(events),
        };
    }

    pub fn parseStatement(self: *StatementParser, stream: anytype) void {
        const kind = stream.current().kind;

        switch (kind) {
            .kw_let, .kw_var, .kw_const => self.parseVarDecl(stream),
            .kw_if => self.parseIfStatement(stream),
            .kw_while => self.parseWhileStatement(stream),
            .kw_for => self.parseForStatement(stream),
            .kw_loop => self.parseLoopStatement(stream),
            .kw_return => self.parseReturnStatement(stream),
            .kw_break => {
                _ = self.events.startNode(.break_stmt);
                self.eatToken(stream);
                if (stream.at(.semicolon)) self.eatToken(stream);
                self.events.finishNode();
            },
            .kw_continue => {
                _ = self.events.startNode(.continue_stmt);
                self.eatToken(stream);
                if (stream.at(.semicolon)) self.eatToken(stream);
                self.events.finishNode();
            },
            .lbrace => self.parseBlockStatement(stream),
            .kw_defer => self.parseDeferStatement(stream),
            .kw_errdefer => self.parseErrdeferStatement(stream),
            else => self.parseExprStatement(stream),
        }
    }

    fn parseVarDecl(self: *StatementParser, stream: anytype) void {
        const is_const = stream.at(.kw_const);
        _ = self.events.startNode(if (is_const) .const_stmt else .let_stmt);
        self.eatToken(stream);

        _ = self.events.startNode(.identifier_pat);
        if (stream.at(.identifier)) self.eatToken(stream);
        self.events.finishNode();

        if (stream.at(.colon)) {
            self.eatToken(stream);
            _ = self.events.startNode(.type_ref);
            self.parseTypeRef(stream);
            self.events.finishNode();
        }

        if (stream.at(.eq)) {
            self.eatToken(stream);
            self.expr_parser.parseExpression(stream);
        }

        if (stream.at(.semicolon)) self.eatToken(stream);
        self.events.finishNode();
    }

    fn parseIfStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.if_stmt);
        self.eatToken(stream);
        self.expr_parser.parseExpression(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockStatement(stream);
        }
        if (stream.at(.kw_else)) {
            self.eatToken(stream);
            if (stream.at(.kw_if)) {
                self.parseIfStatement(stream);
            } else if (stream.at(.lbrace)) {
                self.parseBlockStatement(stream);
            }
        }
        self.events.finishNode();
    }

    fn parseWhileStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.while_stmt);
        self.eatToken(stream);
        self.expr_parser.parseExpression(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockStatement(stream);
        }
        self.events.finishNode();
    }

    fn parseForStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.for_stmt);
        self.eatToken(stream);
        if (stream.at(.identifier)) self.eatToken(stream);
        if (stream.at(.kw_in)) self.eatToken(stream);
        self.expr_parser.parseExpression(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockStatement(stream);
        }
        self.events.finishNode();
    }

    fn parseLoopStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.loop_stmt);
        self.eatToken(stream);
        if (stream.at(.lbrace)) {
            self.parseBlockStatement(stream);
        }
        self.events.finishNode();
    }

    fn parseReturnStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.return_stmt);
        self.eatToken(stream);
        if (!stream.at(.semicolon) and !stream.at(.rbrace) and !stream.at(.eof)) {
            self.expr_parser.parseExpression(stream);
        }
        if (stream.at(.semicolon)) self.eatToken(stream);
        self.events.finishNode();
    }

    pub fn parseBlockStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.block_stmt);
        self.eatToken(stream);
        while (!stream.at(.rbrace) and !stream.at(.eof)) {
            const before = stream.positionAsU32();
            self.parseStatement(stream);
            _ = stream.recoverProgress(before);
        }
        if (stream.at(.rbrace)) self.eatToken(stream);
        self.events.finishNode();
    }

    fn parseExprStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.expr_stmt);
        const before = stream.positionAsU32();
        self.expr_parser.parseExpression(stream);
        if (stream.at(.semicolon)) self.eatToken(stream);
        _ = stream.recoverProgress(before);
        self.events.finishNode();
    }

    fn parseDeferStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.expr_stmt);
        self.eatToken(stream);
        self.parseStatement(stream);
        self.events.finishNode();
    }

    fn parseErrdeferStatement(self: *StatementParser, stream: anytype) void {
        _ = self.events.startNode(.expr_stmt);
        self.eatToken(stream);
        self.parseStatement(stream);
        self.events.finishNode();
    }

    fn parseTypeRef(self: *StatementParser, stream: anytype) void {
        if (stream.at(.identifier) or stream.at(.kw_bool) or stream.at(.kw_i32) or
            stream.at(.kw_i64) or stream.at(.kw_u32) or stream.at(.kw_u64) or
            stream.at(.kw_f32) or stream.at(.kw_f64) or stream.at(.kw_string) or
            stream.at(.kw_void) or stream.at(.kw_any))
        {
            self.eatToken(stream);
        }
    }

    fn eatToken(self: *StatementParser, stream: anytype) void {
        const tok = stream.current();
        self.events.addToken(tokenKindToSyntaxKind(tok.kind), tok.text, tok.span.start, tok.span.end);
        _ = stream.advance();
        stream.skipTrivia();
    }
};
