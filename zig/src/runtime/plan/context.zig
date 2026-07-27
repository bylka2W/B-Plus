pub const PlanContext = extern struct {
    user: ?*anyopaque,
    engine: ?*anyopaque,
    allocator: ?*anyopaque,
    frame: u64,

    pub const empty = PlanContext{
        .user = null,
        .engine = null,
        .allocator = null,
        .frame = 0,
    };
};

pub const PlanHandle = u64;

pub const PLAN_HANDLE_INVALID: PlanHandle = 0;
