const std = @import("std");
const plan_codegen = @import("../../../../compiler/plan/codegen/plan_codegen.zig");
const x64 = @import("../encoder.zig");
const codebuf = @import("../codebuffer.zig");
const Reg = @import("../registers.zig").Reg;

const PlanBinary = plan_codegen.PlanBinary;
const StateLayout = plan_codegen.StateLayout;
const TransitionLayout = plan_codegen.TransitionLayout;

pub const PlanDispatchEmitter = struct {
    plan: *const PlanBinary,
    cbuf: *codebuf.CodeBuffer,

    pub fn init(plan: *const PlanBinary, cbuf: *codebuf.CodeBuffer) PlanDispatchEmitter {
        return .{ .plan = plan, .cbuf = cbuf };
    }

    pub fn emitStateTable(self: PlanDispatchEmitter) !void {
        for (self.plan.states, 0..) |_, i| {
            _ = i;
            try x64.emit(&self.cbuf.bytes, .X86_MOV, &.{
                x64.Operand.reg(.RAX),
                x64.Operand.imm(0),
            });
        }
    }

    pub fn emitJumpTable(self: PlanDispatchEmitter, table_label: u32) !void {
        try x64.emit(&self.cbuf.bytes, .X86_LEA, &.{
            x64.Operand.reg(.RAX),
            x64.Operand.rip(table_label),
        });

        try x64.emit(&self.cbuf.bytes, .X86_MOV, &.{
            x64.Operand.reg(.RDI),
            x64.Operand.reg(.R14),
        });

        try x64.emit(&self.cbuf.bytes, .X86_CMP, &.{
            x64.Operand.reg(.RDI),
            x64.Operand.imm(self.plan.state_count),
        });

        try x64.emit(&self.cbuf.bytes, .X86_JAE, &.{
            x64.Operand.rel32(0),
        });

        try x64.emit(&self.cbuf.bytes, .X86_MOV, &.{
            x64.Operand.reg(.EAX),
            x64.Operand.mem(.RAX, .RDI, 4, 0),
        });

        try x64.emit(&self.cbuf.bytes, .X86_ADD, &.{
            x64.Operand.reg(.RAX),
            x64.Operand.reg(.R14),
        });

        try x64.emit(&self.cbuf.bytes, .X86_JMP, &.{
            x64.Operand.reg(.RAX),
        });
    }

    pub fn emitDispatchBody(self: PlanDispatchEmitter, state_idx: u32) !void {
        if (state_idx >= self.plan.state_count) return;

        const dc = self.plan.dispatch_columns;
        const always_col = self.plan.event_count;

        const always_range_idx = @as(usize, state_idx) * @as(usize, dc) + @as(usize, always_col);
        if (always_range_idx < self.plan.dispatch_table.len) {
            const range = self.plan.dispatch_table[always_range_idx];
            if (range.start != 0xFFFF_FFFF) {
                if (range.start < self.plan.transition_count) {
                    const t = self.plan.transitions[range.start];
                    _ = t;
                }
            }
        }
    }

    pub fn emitTransitionCheck(
        self: PlanDispatchEmitter,
        trans: TransitionLayout,
        event_ptr_reg: Reg,
        match_label: u32,
    ) !void {
        _ = self;
        _ = trans;
        _ = event_ptr_reg;
        _ = match_label;
    }

    pub fn emitChangeState(
        self: PlanDispatchEmitter,
        target_state: u32,
        cur_state_offset: i32,
    ) !void {
        _ = self;
        try x64.emit(&self.cbuf.bytes, .X86_MOV, &.{
            x64.Operand.mem(.RBP, null, 1, cur_state_offset),
            x64.Operand.imm(target_state),
        });
    }
};
