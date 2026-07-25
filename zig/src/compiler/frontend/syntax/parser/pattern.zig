const std = @import("std");
const events_mod = @import("events.zig");
const token_kind = @import("../token/token_kind.zig");
const kind_mod = @import("../kind/syntax_kind.zig");
const tokenKindToSyntaxKind = kind_mod.tokenKindToSyntaxKind;

pub const TokenKind = token_kind.TokenKind;
pub const EventSink = events_mod.EventSink;
pub const SyntaxKind = events_mod.SyntaxKind;

pub const PatternParser = struct {
    events: *EventSink,

    pub fn init(events: *EventSink) PatternParser {
        return .{ .events = events };
    }

    pub fn parsePattern(self: *PatternParser, stream: anytype) void {
        if (stream.at(.underscore)) {
            _ = self.events.startNode(.wildcard_pat);
            self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (stream.at(.int_literal) or stream.at(.string_literal) or
            stream.at(.true_literal) or stream.at(.false_literal) or
            stream.at(.char_literal))
        {
            _ = self.events.startNode(.literal_pat);
            self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (stream.at(.lparen)) {
            _ = self.events.startNode(.tuple_pat);
            self.eatToken(stream);
            while (!stream.at(.rparen) and !stream.at(.eof)) {
                const before = stream.positionAsU32();
                self.parsePattern(stream);
                if (stream.at(.comma)) self.eatToken(stream);
                _ = stream.recoverProgress(before);
            }
            if (stream.at(.rparen)) self.eatToken(stream);
            self.events.finishNode();
            return;
        }

        if (stream.at(.identifier) or stream.at(.kw_self) or stream.at(.kw_true) or
            stream.at(.kw_false) or stream.at(.kw_null))
        {
            _ = self.events.startNode(.identifier_pat);
            self.eatToken(stream);
            if (stream.at(.at)) {
                self.eatToken(stream);
                _ = self.events.startNode(.identifier_pat);
                self.eatToken(stream);
                self.events.finishNode();
            }
            self.events.finishNode();
            return;
        }

        if (stream.at(.dot_dot)) {
            _ = self.events.startNode(.range_pat);
            self.eatToken(stream);
            self.parsePattern(stream);
            self.events.finishNode();
            return;
        }

        _ = self.events.startNode(.wildcard_pat);
        self.events.finishNode();
    }

    fn eatToken(self: *PatternParser, stream: anytype) void {
        const tok = stream.current();
        self.events.addToken(tokenKindToSyntaxKind(tok.kind), tok.text, tok.span.start, tok.span.end);
        _ = stream.advance();
        stream.skipTrivia();
    }
};
