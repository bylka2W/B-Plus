//! Test root for the safety analyses.
//!
//! `safety/init_checker.zig` sits next to sources it does not own, so its
//! relative imports escape its own directory. A test root in `src/compiler/`
//! keeps them inside the module, which lets the definite-initialization
//! regression tests run as part of `zig build test`.

const std = @import("std");
const init_checker = @import("safety/init_checker.zig");

test {
    std.testing.refAllDecls(init_checker.InitChecker);
}
