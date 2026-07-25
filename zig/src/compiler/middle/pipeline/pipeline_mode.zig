pub const PipelineMode = enum {
    plan,
    metal,

    pub fn name(self: PipelineMode) []const u8 {
        return switch (self) {
            .plan => "plan",
            .metal => "metal",
        };
    }
};

test "PipelineMode: plan" {
    const m = PipelineMode.plan;
    try std.testing.expectEqualStrings("plan", m.name());
}

test "PipelineMode: metal" {
    const m = PipelineMode.metal;
    try std.testing.expectEqualStrings("metal", m.name());
}
