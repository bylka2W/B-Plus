use inkwell::values::IntValue;
use inkwell::IntPredicate;

/// LLVM intrinsic wrappers for B+ codegen.
/// These generate LLVM IR intrinsics directly instead of emitting C++.

/// Generate llvm.prefetch intrinsic call.
pub fn prefetch<'ctx>() -> &'static str {
    "call void @llvm.prefetch.p0i8(i8* %addr, i32 0, i32 3, i32 1)"
}

/// Generate llvm.assume for alignment hints.
pub fn assume_aligned<'ctx>(ptr: &IntValue<'ctx>, alignment: u32) -> String {
    format!(
        "call void @llvm.assume(i1 icmp eq (i64 and (i64 ptrtoint ({}* %ptr to i64), i64 {}), i64 0))",
        if alignment == 32 { "i8" } else { "i8" },
        alignment - 1
    )
}

/// Generate fence for store forwarding safety.
pub fn store_fence() -> &'static str {
    "fence seq_cst"
}

/// Memory barrier hint for NUMA binding.
pub fn numa_barrier() -> &'static str {
    "fence acquire"
}
