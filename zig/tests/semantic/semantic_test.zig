const std = @import("std");
const testing = std.testing;
const frontend_test = @import("frontend_test");
const path = std.fs.path;

const TestCase = struct {
    name: []const u8,
    has_error: bool,
};

const cases: []const TestCase = &.{
    .{ .name = "01_undefined_var_in_print.b+", .has_error = true },
    .{ .name = "02_undefined_var_arithmetic.b+", .has_error = true },
    .{ .name = "03_undefined_var_as_condition.b+", .has_error = true },
    .{ .name = "04_undefined_var_in_assignment.b+", .has_error = true },
    .{ .name = "05_undefined_var_in_while.b+", .has_error = true },
    .{ .name = "06_number_as_if_condition.b+", .has_error = true },
    .{ .name = "07_string_as_condition.b+", .has_error = true },
    .{ .name = "08_struct_as_condition.b+", .has_error = true },
    .{ .name = "09_bare_number.b+", .has_error = true },
    .{ .name = "10_bare_string.b+", .has_error = true },
    .{ .name = "11_self_ref_init.b+", .has_error = true },
    .{ .name = "12_too_many_args.b+", .has_error = true },
    .{ .name = "13_too_few_args.b+", .has_error = true },
    .{ .name = "14_call_nonexistent_fn.b+", .has_error = true },
    .{ .name = "15_call_undefined_with_args.b+", .has_error = true },
    .{ .name = "16_return_inconsistency.b+", .has_error = true },
    .{ .name = "17_return_value_vs_no_return.b+", .has_error = true },
    .{ .name = "18_use_local_outside.b+", .has_error = true },
    .{ .name = "19_entry_var_in_fn.b+", .has_error = true },
    .{ .name = "20_break_outside_loop.b+", .has_error = true },
    .{ .name = "21_continue_outside_loop.b+", .has_error = true },
    .{ .name = "22_return_in_entry.b+", .has_error = true },
    .{ .name = "23_import_nonexistent.b+", .has_error = true },
    .{ .name = "24_empty_state.b+", .has_error = true },
    .{ .name = "25_state_no_entry.b+", .has_error = true },
    .{ .name = "26_always_to_self.b+", .has_error = false },
    .{ .name = "27_enum_value_as_state_var.b+", .has_error = true },
    .{ .name = "28_struct_field_access.b+", .has_error = true },
    .{ .name = "29_nested_struct_init.b+", .has_error = true },
    .{ .name = "30_negative_array_index.b+", .has_error = true },
    .{ .name = "31_undefined_state_transition.b+", .has_error = true },
    .{ .name = "32_undefined_struct_as_type.b+", .has_error = true },
    .{ .name = "33_invalid_enum_value.b+", .has_error = true },
    .{ .name = "34_invalid_struct_field.b+", .has_error = true },
    .{ .name = "35_return_type_no_return.b+", .has_error = true },
    .{ .name = "36_return_without_type.b+", .has_error = true },
    .{ .name = "37_valid_state_transition.b+", .has_error = false },
    .{ .name = "38_valid_struct_field.b+", .has_error = false },
    .{ .name = "39_valid_enum_value.b+", .has_error = false },
    .{ .name = "40_valid_return_type.b+", .has_error = false },
    .{ .name = "41_type_mismatch_assignment.b+", .has_error = true },
    .{ .name = "42_type_match_assignment.b+", .has_error = false },
    .{ .name = "43_type_match_float.b+", .has_error = false },
    .{ .name = "44_type_match_string.b+", .has_error = false },
    .{ .name = "45_type_inference_arithmetic.b+", .has_error = true },
    .{ .name = "46_type_mismatch_bool.b+", .has_error = true },
    .{ .name = "47_binary_type_mismatch.b+", .has_error = true },
    .{ .name = "48_func_arg_type_mismatch.b+", .has_error = true },
    .{ .name = "49_func_arg_type_mismatch2.b+", .has_error = true },
    .{ .name = "50_func_arg_type_valid.b+", .has_error = false },
    .{ .name = "51_binary_type_valid.b+", .has_error = false },
    .{ .name = "52_binary_type_string_concat.b+", .has_error = false },
    .{ .name = "53_scope_param_lookup.b+", .has_error = false },
    .{ .name = "54_scope_global_func.b+", .has_error = false },
    .{ .name = "55_reassign_type_mismatch.b+", .has_error = true },
};

test "semantic contracts" {
    const allocator = testing.allocator;
    for (cases) |c| {
        const file_path = try path.join(allocator, &.{ "tests/semantic", c.name });
        defer allocator.free(file_path);
        const src = try std.fs.cwd().readFileAlloc(allocator, file_path, 32 * 1024);
        defer allocator.free(src);
        var result = try frontend_test.typeCheckSource(src, allocator);
        defer result.errors.deinit();
        defer result.hir_arena.deinit();
        defer result.engine.deinit();
        defer result.resolver.deinit();
        defer result.ast_arena.deinit();

        const has_error = result.errors.count() > 0;
                if (c.has_error != has_error) {
    std.debug.print(
        "SEMANTIC MISMATCH: %{s} expected_error=%{?} actual_error=%{?}",
        .{ c.name, c.has_error, has_error },
    );
    return error.TestExpectedEqual;
}
    }
}
