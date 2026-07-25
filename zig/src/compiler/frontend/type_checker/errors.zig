const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");
const SourceSpan = @import("../source/location/span.zig").SourceSpan;

pub const TypeError = struct {
    kind: ErrorKind,
    span: SourceSpan,

    pub const ErrorKind = union(enum) {
        type_mismatch: TypeMismatchData,
        undefined_var: UndefinedVarData,
        already_defined: AlreadyDefinedData,
        missing_return: MissingReturnData,
        return_type_mismatch: TypeMismatchData,
        not_callable: NotCallableData,
        wrong_arg_count: WrongArgCountData,
        arg_type_mismatch: TypeMismatchData,
        cannot_coerce: CannotCoerceData,
        missing_annotation: MissingAnnotationData,
        not_a_function: void,
        invalid_binop: InvalidBinOpData,
        invalid_unop: InvalidUnOpData,
        infinite_type: void,
        break_outside_loop: void,
        continue_outside_loop: void,
        break_type_mismatch: TypeMismatchData,
        unresolved_type: UnresolvedTypeData,
        not_indexable: void,
        index_not_integer: void,
        field_not_found: FieldNotFoundData,
        not_struct_for_field: void,
        match_arm_type_mismatch: TypeMismatchData,
        unresolved_inference_var: UnresolvedInferenceData,
        arg_count_mismatch: WrongArgCountData,
    };

    pub const TypeMismatchData = struct {
        expected: []const u8,
        found: []const u8,
    };

    pub const UndefinedVarData = struct {
        name: []const u8,
    };

    pub const AlreadyDefinedData = struct {
        name: []const u8,
    };

    pub const MissingReturnData = struct {};

    pub const NotCallableData = struct {};

    pub const WrongArgCountData = struct {
        expected: u32,
        found: u32,
    };

    pub const CannotCoerceData = struct {
        from: []const u8,
        to: []const u8,
    };

    pub const MissingAnnotationData = struct {};

    pub const InvalidBinOpData = struct {
        op: []const u8,
        left: []const u8,
        right: []const u8,
    };

    pub const InvalidUnOpData = struct {
        op: []const u8,
        operand: []const u8,
    };

    pub const UnresolvedTypeData = struct {
        name: []const u8,
    };

    pub const FieldNotFoundData = struct {
        field: []const u8,
    };

    pub const UnresolvedInferenceData = struct {
        expr_id: u32,
    };
};

pub const ErrorList = struct {
    errors: std.ArrayList(TypeError),
    alloc: std.mem.Allocator,
    had_error: bool,

    pub fn init(alloc: std.mem.Allocator) ErrorList {
        return .{
            .errors = std.ArrayList(TypeError).init(alloc),
            .alloc = alloc,
            .had_error = false,
        };
    }

    pub fn deinit(self: *ErrorList) void {
        self.errors.deinit();
    }

    pub fn report(self: *ErrorList, kind: TypeError.ErrorKind, span: SourceSpan) void {
        self.errors.append(.{ .kind = kind, .span = span }) catch return;
        self.had_error = true;
    }

    pub fn count(self: *const ErrorList) u32 {
        return @intCast(self.errors.items.len);
    }

    pub fn get(self: *const ErrorList, idx: u32) ?TypeError {
        if (idx >= self.errors.items.len) return null;
        return self.errors.items[idx];
    }
};
