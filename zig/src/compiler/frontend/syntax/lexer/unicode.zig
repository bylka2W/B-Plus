pub fn isAscii(ch: u8) bool {
    return ch < 0x80;
}

pub fn isAsciiAlphabetic(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

pub fn isAsciiDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

pub fn isAsciiAlphanumeric(ch: u8) bool {
    return isAsciiAlphabetic(ch) or isAsciiDigit(ch);
}

pub fn isAsciiIdentStart(ch: u8) bool {
    return isAsciiAlphabetic(ch) or ch == '_';
}

pub fn isAsciiIdentContinue(ch: u8) bool {
    return isAsciiAlphanumeric(ch) or ch == '_';
}

pub fn utf8ByteSequenceLength(first_byte: u8) ?u4 {
    if (first_byte < 0x80) return 1;
    if (first_byte >= 0xC0 and first_byte < 0xE0) return 2;
    if (first_byte >= 0xE0 and first_byte < 0xF0) return 3;
    if (first_byte >= 0xF0 and first_byte < 0xF8) return 4;
    return null;
}

pub fn utf8IsContinuationByte(ch: u8) bool {
    return (ch & 0xC0) == 0x80;
}

pub fn utf8Decode(bytes: []const u8) ?struct { codepoint: u21, length: u4 } {
    if (bytes.len == 0) return null;
    const first = bytes[0];
    if (first < 0x80) return .{ .codepoint = first, .length = 1 };

    const seq_len = utf8ByteSequenceLength(first) orelse return null;
    if (bytes.len < seq_len) return null;

    var cp: u21 = first & ((1 << (8 - @as(u4, seq_len))) - 1);
    for (bytes[1..seq_len]) |ch| {
        if (!utf8IsContinuationByte(ch)) return null;
        cp = (cp << 6) | (ch & 0x3F);
    }

    if (cp > 0x10FFFF) return null;
    if (cp >= 0xD800 and cp <= 0xDFFF) return null;

    return .{ .codepoint = cp, .length = seq_len };
}

pub fn isXidStart(codepoint: u21) bool {
    if (codepoint < 0x80) return isAsciiIdentStart(@intCast(codepoint));
    return codepoint == '_' or (codepoint >= 0x41 and codepoint <= 0x5A) or
        (codepoint >= 0x61 and codepoint <= 0x7A) or
        (codepoint >= 0xC0 and codepoint <= 0xD6) or
        (codepoint >= 0xD8 and codepoint <= 0xF6) or
        (codepoint >= 0xF8 and codepoint <= 0x2FF);
}

pub fn isXidContinue(codepoint: u21) bool {
    if (codepoint < 0x80) return isAsciiIdentContinue(@intCast(codepoint));
    return isXidStart(codepoint) or
        (codepoint >= 0x300 and codepoint <= 0x36F) or
        (codepoint >= 0x203F and codepoint <= 0x2040);
}
