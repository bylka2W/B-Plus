const std = @import("std");
const machine = @import("machine.zig");
const plan_ir = @import("../../compiler/plan/ir/plan.zig");

const PlanMachine = machine.PlanMachine;
const PlanEventId = plan_ir.PlanEventId;

pub const EventEntry = struct {
    name: []const u8,
    id: PlanEventId,
};

pub const CliAdapter = struct {
    machine: *PlanMachine,
    event_names: []const EventEntry,

    pub fn init(m: *PlanMachine, event_names: []const EventEntry) CliAdapter {
        return .{
            .machine = m,
            .event_names = event_names,
        };
    }

    pub fn lookupEvent(self: CliAdapter, name: []const u8) ?PlanEventId {
        const lower = toLower(name);
        for (self.event_names) |entry| {
            if (std.mem.eql(u8, entry.name, lower)) {
                return entry.id;
            }
        }
        return null;
    }

    pub fn handleLine(self: *CliAdapter, line: []const u8) ?machine.DispatchResult {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return null;

        if (std.mem.eql(u8, trimmed, "quit") or std.mem.eql(u8, trimmed, "exit")) {
            self.machine.stop();
            return .machine_not_running;
        }

        const event_id = self.lookupEvent(trimmed) orelse {
            std.debug.print("Unknown event: '{s}'\n", .{trimmed});
            return null;
        };

        return self.machine.sendEvent(event_id);
    }

    pub fn stdinLoop(self: *CliAdapter) void {
        var buf: [256]u8 = undefined;
        const stdin = std.io.getStdIn().reader();

        while (self.machine.isRunning()) {
            std.debug.print("> ", .{});
            if (stdin.readUntilDelimiter(&buf, '\n')) |line| {
                const result = self.handleLine(line) orelse continue;
                switch (result) {
                    .transitioned => std.debug.print("[transitioned]\n", .{}),
                    .always_transitioned => std.debug.print("[always]\n", .{}),
                    .no_transition => std.debug.print("[no transition]\n", .{}),
                    .guard_rejected => std.debug.print("[guard rejected]\n", .{}),
                    .machine_not_running => std.debug.print("[stopped]\n", .{}),
                    .machine_paused => std.debug.print("[paused]\n", .{}),
                }
            } else |_| {
                break;
            }
        }
    }
};

fn toLower(s: []const u8) []const u8 {
    for (s, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            return s[0..i] ++ &[_]u8{c + 32} ++ s[i + 1 ..];
        }
    }
    return s;
}
