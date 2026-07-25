const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const TypeId = bir.TypeId;
const Op = bir.Op;

pub const ErrorCode = enum {
    // Module-level
    duplicate_function_name,
    invalid_function_id,

    // Function-level
    empty_function,
    missing_entry_block,
    block_has_no_terminator,
    instruction_after_terminator,
    invalid_block_id,

    // CFG
    successor_out_of_range,
    predecessor_symmetry_broken,
    entry_block_has_predecessor,
    unreachable_block,

    // SSA
    value_defined_twice,
    value_used_before_def,
    value_does_not_dominate_use,
    phi_value_does_not_dominate_pred,

    // Phi
    phi_incoming_count_mismatch,
    phi_incoming_block_not_predecessor,
    phi_incoming_value_type_mismatch,
    phi_duplicate_incoming_block,
    phi_not_at_block_start,

    // Type system
    type_mismatch,
    type_operand_count_mismatch,
    type_not_integer,
    type_not_float,
    type_not_pointer,
    type_not_comparable,
    type_not_numeric,

    // Instruction
    invalid_operand_count,
    alloca_type_void,
    const_type_void,
    unary_requires_operand,
    binary_requires_two_operands,
    terminator_not_last,

    // Memory
    load_type_mismatch,
    store_type_mismatch,
    store_target_not_pointer,
    alloca_result_not_used,

    // Calls
    call_argument_count_mismatch,
    call_argument_type_mismatch,
    call_callee_not_function,
    call_return_type_mismatch,

    // Use-def
    use_def_symmetry_broken,
    data_ref_use_def_symmetry_broken,
};

pub const Diagnostic = struct {
    code: ErrorCode,
    func_id: ?FunctionId = null,
    func_name: ?[]const u8 = null,
    block_id: ?BlockId = null,
    block_name: ?[]const u8 = null,
    inst_idx: ?usize = null,
    value_id: ?ValueId = null,
    expected_value: ?ValueId = null,
    type_id: ?TypeId = null,
    expected_type: ?TypeId = null,
    other_type_id: ?TypeId = null,
    op: ?Op = null,
    message: ?[]const u8 = null,

    pub fn format(self: Diagnostic, module: ?*const bir.Module) DiagnosticFormatter {
        return .{ .diag = self, .module = module };
    }
};

pub const DiagnosticFormatter = struct {
    diag: Diagnostic,
    module: ?*const bir.Module,

    pub fn format(self: DiagnosticFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        const w = writer;

        try w.writeAll("error: ");
        try w.writeAll(@tagName(self.diag.code));

        if (self.diag.message) |msg| {
            try w.writeAll(": ");
            try w.writeAll(msg);
        }
        try w.writeAll("\n");

        if (self.diag.func_name) |name| {
            try w.writeAll("  in function: '");
            try w.writeAll(name);
            try w.writeAll("'\n");
        }

        if (self.diag.block_name) |name| {
            try w.writeAll("  in block: '");
            try w.writeAll(name);
            try w.writeAll("'\n");
        } else if (self.diag.block_id) |bid| {
            try w.print("  in block: b{d}\n", .{bid});
        }

        if (self.diag.inst_idx) |idx| {
            try w.print("  at instruction index: {d}\n", .{idx});
        }

        if (self.diag.value_id) |vid| {
            try w.print("  for value: %{d}\n", .{vid});
        }

        if (self.diag.type_id) |tid| {
            try w.print("  type: %{d}\n", .{tid});
        }

        if (self.diag.expected_type) |et| {
            try w.print("  expected type: %{d}\n", .{et});
        }

        if (self.diag.other_type_id) |ot| {
            try w.print("  got type: %{d}\n", .{ot});
        }

        if (self.diag.op) |op| {
            try w.print("  opcode: .{s}\n", .{@tagName(op)});
        }

        return;
    }
};

pub const DiagnosticList = struct {
    list: std.ArrayList(Diagnostic),
    allocator: Allocator,

    pub fn init(allocator: Allocator) DiagnosticList {
        return .{
            .list = std.ArrayList(Diagnostic).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.list.deinit();
    }

    pub fn push(self: *DiagnosticList, diag: Diagnostic) !void {
        try self.list.append(diag);
    }

    pub fn len(self: *const DiagnosticList) usize {
        return self.list.items.len;
    }

    pub fn hasErrors(self: *const DiagnosticList) bool {
        return self.list.items.len > 0;
    }

    pub fn printAll(self: *const DiagnosticList, writer: anytype, module: ?*const bir.Module) !void {
        for (self.list.items) |diag| {
            try diag.format(module).format("", .{}, writer);
        }
    }
};
