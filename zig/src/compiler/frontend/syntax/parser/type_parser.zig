const std = @import("std");
const events_mod = @import("events.zig");
const token_kind = @import("../token/token_kind.zig");
const kind_mod = @import("../kind/syntax_kind.zig");
const tokenKindToSyntaxKind = kind_mod.tokenKindToSyntaxKind;

pub const TokenKind = token_kind.TokenKind;
pub const EventSink = events_mod.EventSink;
pub const SyntaxKind = events_mod.SyntaxKind;

pub const TypeParser = struct {
    events: *EventSink,

    pub fn init(events: *EventSink) TypeParser {
        return .{ .events = events };
    }

    pub fn parseType(self: *TypeParser, stream: anytype) void {
        if (stream.at(.question)) {
            _ = self.events.startNode(.optional_type);
            _ = self.events.startNode(.type_ref);
            self.eatToken(stream);
            self.parseTypeAtom(stream);
            self.events.finishNode();
            self.events.finishNode();
            return;
        }
        self.parseTypeAtom(stream);
    }

    fn parseTypeAtom(self: *TypeParser, stream: anytype) void {
        if (stream.at(.star)) {
            _ = self.events.startNode(.pointer_type);
            self.eatToken(stream);
            if (stream.at(.kw_mut)) self.eatToken(stream);
            self.parseTypeAtom(stream);
            self.events.finishNode();
            return;
        }

        if (stream.at(.lbracket)) {
            _ = self.events.startNode(.array_type);
            self.eatToken(stream);
            if (!stream.at(.rbracket)) {
                _ = self.events.startNode(.type_ref);
                self.parseExpressionSimple(stream);
                self.events.finishNode();
            }
            if (stream.at(.comma)) self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (stream.at(.lparen)) {
            self.parseTupleType(stream);
            return;
        }

        if (stream.at(.identifier) or stream.at(.kw_bool) or stream.at(.kw_i8) or
            stream.at(.kw_i16) or stream.at(.kw_i32) or stream.at(.kw_i64) or
            stream.at(.kw_u8) or stream.at(.kw_u16) or stream.at(.kw_u32) or
            stream.at(.kw_u64) or stream.at(.kw_f32) or stream.at(.kw_f64) or
            stream.at(.kw_string) or stream.at(.kw_void) or stream.at(.kw_any))
        {
            _ = self.events.startNode(.named_type);
            self.eatToken(stream);
            while (stream.at(.colon_colon)) {
                const before = stream.positionAsU32();
                self.eatToken(stream);
                if (stream.at(.identifier)) self.eatToken(stream);
                _ = stream.recoverProgress(before);
            }
            if (stream.at(.lparen)) {
                self.parseTypeArgs(stream);
            }
            self.events.finishNode();
            return;
        }

        _ = self.events.startNode(.type_ref);
        self.events.finishNode();
    }

    fn parseTupleType(self: *TypeParser, stream: anytype) void {
        _ = self.events.startNode(.tuple_type);
        self.eatToken(stream);
        while (!stream.at(.rparen) and !stream.at(.eof)) {
            const before = stream.positionAsU32();
            self.parseType(stream);
            if (stream.at(.comma)) self.eatToken(stream);
            _ = stream.recoverProgress(before);
        }
        if (stream.at(.rparen)) self.eatToken(stream);
        self.events.finishNode();
    }

    fn parseTypeArgs(self: *TypeParser, stream: anytype) void {
        self.eatToken(stream);
        while (!stream.at(.rparen) and !stream.at(.eof)) {
            const before = stream.positionAsU32();
            self.parseType(stream);
            if (stream.at(.comma)) self.eatToken(stream);
            _ = stream.recoverProgress(before);
        }
        if (stream.at(.rparen)) self.eatToken(stream);
    }

    fn parseExpressionSimple(self: *TypeParser, stream: anytype) void {
        if (stream.at(.int_literal)) {
            self.eatToken(stream);
        }
    }

    fn eatToken(self: *TypeParser, stream: anytype) void {
        const tok = stream.current();
        self.events.addToken(tokenKindToSyntaxKind(tok.kind), tok.text, tok.span.start, tok.span.end);
        _ = stream.advance();
        stream.skipTrivia();
    }
};
