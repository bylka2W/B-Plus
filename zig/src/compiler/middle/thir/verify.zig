const std = @import("std");
const thir = @import("thir.zig");
const BlockId = thir.BlockId;

pub const VerifyError = error{
    InvalidBlock,
    InvalidValue,
    MissingTerminator,
    DanglingBreak,
    DanglingContinue,
    UnreachableValue,
    TypeMismatch,
    MissingEntry,
};

pub const VerifyContext = struct {
    module: *thir.ThirModule,
    errors: std.ArrayList(VerifyError),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, module: *thir.ThirModule) VerifyContext {
        return .{
            .allocator = allocator,
            .module = module,
            .errors = std.ArrayList(VerifyError).init(allocator),
        };
    }

    pub fn deinit(self: *VerifyContext) void {
        self.errors.deinit();
    }

    pub fn verify(self: *VerifyContext) !bool {
        for (self.module.functions.items) |*func| {
            try self.verifyFunction(func);
        }
        return self.errors.items.len == 0;
    }

    fn verifyFunction(self: *VerifyContext, func: *thir.ThirFunction) !void {
        const body = func.body orelse return;

        if (body.blocks.len == 0) {
            try self.errors.append(error.MissingEntry);
            return;
        }

        // Check entry block exists
        if (!body.entry.isValid() or body.entry.index >= body.blocks.len) {
            try self.errors.append(error.InvalidBlock);
            return;
        }

        // Verify each block
        for (body.blocks, 0..) |block, i| {
            try self.verifyBlock(block, BlockId.new(@intCast(i)), body.blocks.len);
        }
    }

    fn verifyBlock(self: *VerifyContext, block: thir.BasicBlock, idx: thir.BlockId, total: usize) !void {
        _ = idx;
        switch (block.terminator) {
            .br => |target| {
                if (!target.isValid() or target.index >= total) try self.errors.append(error.InvalidBlock);
            },
            .cond_br => |cb| {
                if (!cb.then.isValid() or cb.then.index >= total) try self.errors.append(error.InvalidBlock);
                if (!cb.else_.isValid() or cb.else_.index >= total) try self.errors.append(error.InvalidBlock);
            },
            .switch_br => |sw| {
                if (sw.default) |d| {
                    if (!d.isValid() or d.index >= total) try self.errors.append(error.InvalidBlock);
                }
                for (sw.cases) |c| {
                    if (!c.target.isValid() or c.target.index >= total) try self.errors.append(error.InvalidBlock);
                }
            },
            .return_ret => {},
            .unreachable_term => {},
            .diverge => {},
        }

        for (block.stmts) |stmt| {
            switch (stmt.kind) {
                .break_stmt => |b| {
                    if (!b.target_loop.isValid() or b.target_loop.index >= total) try self.errors.append(error.DanglingBreak);
                },
                .continue_stmt => |c| {
                    if (!c.target_loop.isValid() or c.target_loop.index >= total) try self.errors.append(error.DanglingContinue);
                },
                else => {},
            }
        }
    }
};
