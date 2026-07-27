pub const BPlusPlanHandle = u64;
pub const BPlusDispatchResult = u8;

pub const BPLUS_DISPATCH_TRANSITIONED: BPlusDispatchResult = 0;
pub const BPLUS_DISPATCH_ALWAYS: BPlusDispatchResult = 1;
pub const BPLUS_DISPATCH_NO_TRANSITION: BPlusDispatchResult = 2;
pub const BPLUS_DISPATCH_GUARD_REJECTED: BPlusDispatchResult = 3;
pub const BPLUS_DISPATCH_NOT_RUNNING: BPlusDispatchResult = 4;
pub const BPLUS_DISPATCH_PAUSED: BPlusDispatchResult = 5;

pub const BPlusPlanConfig = extern struct {
    graph: ?*anyopaque,
    functions: ?*anyopaque,
    user_ctx: ?*anyopaque,
    engine: ?*anyopaque,
};
