const std = @import("std");

/// LLVM bitstream writer matching LLVM 13 format.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    words: std.ArrayListUnmanaged(u32),
    cur_bit: u32,
    block_size_words: std.ArrayListUnmanaged(u32),
    code_len_stack: std.ArrayListUnmanaged(u32),

    pub fn init(a: std.mem.Allocator) Writer {
        return .{
            .allocator = a,
            .words = .{},
            .cur_bit = 0,
            .block_size_words = .{},
            .code_len_stack = .{},
        };
    }

    pub fn deinit(self: *Writer) void {
        self.words.deinit(self.allocator);
        self.block_size_words.deinit(self.allocator);
        self.code_len_stack.deinit(self.allocator);
    }

    fn grow(self: *Writer, need: u32) !void {
        const n = (self.cur_bit + need + 31) / 32;
        while (self.words.items.len < n)
            try self.words.append(self.allocator, 0);
    }

    /// Put `val` in lowest `n` bits, LSB-first (matching LLVM 13 BitstreamWriter::Emit).
    /// LLVM packs values into words from bit 0 upward with no bit reversal.
    fn put(self: *Writer, val: u32, n: u32) !void {
        if (n == 0) return;
        try self.grow(n);
        var v = val;
        var remaining = n;
        while (remaining > 0) {
            const wi = self.cur_bit / 32;
            const bi = self.cur_bit % 32;
            const space = 32 - bi;
            const take = @min(remaining, space);
            const mask = (@as(u32, 1) << @intCast(take)) -% 1;
            const bits = v & mask;
            self.words.items[wi] |= bits << @intCast(bi);
            v >>= @intCast(take);
            self.cur_bit += take;
            remaining -= take;
        }
    }

    fn align_(self: *Writer) !void {
        const off = self.cur_bit % 32;
        if (off != 0) try self.put(0, 32 - off);
    }

    /// Current word index (0-based).
    fn wordIndex(self: *Writer) u32 {
        return self.cur_bit / 32;
    }

    /// VBR(n): continuation bit 0 (LSB), data bits n-1..1 (LLVM 3.0+ format).
    pub fn vbr(self: *Writer, value: u64, n: u32) !void {
        const db = n - 1;
        const msk = (@as(u64, 1) << @intCast(db)) - 1;
        var v = value;
        while (v >= (@as(u64, 1) << @intCast(db))) {
            try self.put(@as(u32, @intCast((v & msk) << 1)) | 1, n);
            v >>= @intCast(db);
        }
        try self.put(@as(u32, @intCast((v & msk) << 1)), n);
    }

    pub fn fixed(self: *Writer, val: u32, n: u32) !void {
        try self.put(val, n);
    }

    /// Emit a full 32-bit word (little-endian byte order, MSB-first bits).
    fn emitWord(self: *Writer, val: u32) !void {
        // Flush any partial bits in the current word, then write 'val' as the next word.
        try self.align_();
        const wi = self.wordIndex();
        try self.grow(32);
        self.words.items[wi] = val;
        self.cur_bit += 32;
    }

    /// Backpatch a 32-bit word at a given word index.
    fn backpatchWord(self: *Writer, wi: u32, val: u32) void {
        if (wi < self.words.items.len) {
            self.words.items[wi] = val;
        }
    }

    /// Enter subblock (LLVM 13 format).
    /// Layout: [ENTER_SUBBLOCK(2)] [BlockID VBR(8)] [CodeLen VBR(4)] [align32] [BlockSize: 32-bit fixed word]
    pub fn enterBlock(self: *Writer, id: u32, code_len: u32) !void {
        try self.fixed(1, 2);   // ENTER_SUBBLOCK
        try self.vbr(id, 8);    // BlockID VBR(8)
        try self.vbr(code_len, 4); // CodeLen VBR(4)

        // emitWord handles 32-bit alignment then writes the block-size word
        try self.emitWord(0);    // placeholder 32-bit block size
        const wi = self.wordIndex() - 1;
        try self.block_size_words.append(self.allocator, wi);
        try self.code_len_stack.append(self.allocator, code_len);
    }

    /// Exit subblock (matches LLVM 13 ExitBlock).
    /// Writes END_BLOCK, aligns to word boundary, pushes a new word,
    /// then backpatches block size.
    pub fn exitBlock(self: *Writer) !void {
        try self.fixed(0, 2);    // END_BLOCK
        try self.align_();        // align to word boundary (LLVM FlushToWord)

        const end_wi = self.wordIndex();
        const size_wi = self.block_size_words.pop() orelse return;
        _ = self.code_len_stack.pop();

        const sz = end_wi - size_wi - 1;
        self.backpatchWord(size_wi, sz);
        const debug = @import("std").debug;
        debug.print("exitBlock: size_wi={d}, end_wi={d}, sz={d} (words.len={d})\n", .{ size_wi, end_wi, sz, self.words.items.len });
    }

    /// Unabbreviated record: abbrev=3, code=VBR(CodeLen), num_elts=VBR6, operands=VBR6...
    /// LLVM 13 UNABBREV_RECORD includes an explicit operand count after the code.
    pub fn record(self: *Writer, code: u32, ops: []const u32) !void {
        const code_len = self.code_len_stack.getLast();
        try self.fixed(3, 2);
        try self.vbr(code, code_len);
        try self.vbr(@as(u32, @intCast(ops.len)), 6);
        for (ops) |op| try self.vbr(op, 6);
    }

    pub fn finish(self: *Writer) ![]u8 {
        try self.align_();
        const nw = self.wordIndex();
        self.words.shrinkAndFree(self.allocator, nw);
        return std.mem.sliceAsBytes(self.words.items);
    }
};
