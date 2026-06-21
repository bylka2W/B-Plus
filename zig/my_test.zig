const std = @import("std");

const MachineHandle = struct {
    id: u32,
    total_heat: u32 = 0,
    current_heat: u32 = 0,
    tier: u2 = 3, 
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ЗАПУСК КАСТОМНОГО ТЕСТА B-PLUS ===\n", .{});

    var machines = try allocator.alloc(MachineHandle, 10);
    defer allocator.free(machines);

    for (machines, 0..) |*m, i| {
        m.* = .{ .id = @intCast(i) };
    }

    var migrations_count: u32 = 0;
    const total_ops: u32 = 50000;

    std.debug.print("Запускаем {d} операций обращения к автоматам...\n", .{total_ops});

    var i: u32 = 0;
    while (i < total_ops) : (i += 1) {
        // Имитируем паттерн нагрузки: 
        // Если индекс делится на 3 — бьем в автомат №7 (высокая нагрузка)
        // Иначе — бьем в автомат на основе остатка от деления
        const target_idx: usize = if (i % 3 == 0) 7 else (i % 10);
        var m = &machines[target_idx];

        m.total_heat += 1;
        m.current_heat += 1;

        if (m.current_heat > 100 and m.tier > 1) {
            m.tier = 1; 
            migrations_count += 1;
            m.current_heat = 0; 
        }
    }

    std.debug.print("\n=== РЕЗУЛЬТАТЫ СИМУЛЯЦИИ ===\n", .{});
    std.debug.print("Всего операций: {d}\n", .{total_ops});
    std.debug.print("Всего миграций в L1: {d}\n", .{migrations_count});

    std.debug.print("\nСостояние автоматов после нагрузки:\n", .{});
    for (machines) |m| {
        std.debug.print("Автомат ID {d}: Общий вызов (Heat) = {d}, Уровень памяти = L{d}\n", .{
            m.id, m.total_heat, m.tier,
        });
    }
}
