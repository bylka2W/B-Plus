const std = @import("std");
const mir = @import("../../mir.zig");
const MInst = mir.MInst;
const MOperand = mir.MOperand;

/// свертки адресов
///
///распознаёт вычисление адресов при переводе BIR в MIR и собирает из него LEA с адресом вида [base + index * scale + offset]
///
///отслеживает откуда берутся значения после mov, shl и add. также запоминает известные числа чтобы правильно определять сдвиги и смещения адресов
///
/// схема вычисления адреса: base + index*scale + disp
///   mov v1, #3           ; сохраняем константу индекса  known_imm(3)
///   mov v5, v2           ; копируем индекс copy(v2)
///   shl v5, v_shift      ; умножаем индекс на 4 через сдвиг тобишь scaled(v2, 4)
///   mov v6, v_base       ; копируем базовый адрес  copy(v1)
///   add v6, v5           ; складываем base и index*4 addr(v1, v2, 4, 0)
///   mov v7, v6           ; передаём вычисленный адрес дальше
///   add v7, v_disp       ; добавляем смещение base + index*4 + disp - lea

const Origin = union(enum) {
    /// vreg хранит известное константное значение полученное из mov v_r, #imm
    known_imm: i64,
    /// vreg хранит копию значения другого операнд полученную через mov v_r, v_s
    copy: MOperand,
    /// vreg хранит значение исходного операнда грубо говоря умноженное на scale
    scaled: struct {
        source: MOperand,
        scale: u8,
    },
    /// vreg хранит адрес в виде base + index*scale + disp
    addr: struct {
        base: MOperand,
        index: MOperand = .{ .imm = 0 },
        scale: u8 = 1,
        disp: i32 = 0,
    },
};

pub const AddrFoldPass = struct {
    pub const name = "addr-fold";
    pub const pass_type = .transform;

    pub fn run(mfunc: *mir.MFunction) !void {
        for (mfunc.blocks.items) |*block| {
            try foldBlock(block, mfunc.allocator);
        }
    }
};

fn foldBlock(block: *mir.MBlock, allocator: std.mem.Allocator) !void {
    var origin = std.AutoHashMap(u32, Origin).init(allocator);
    defer origin.deinit();

    // отслеживаем происхождение значений
    var i: usize = 0;
    while (i < block.instrs.items.len) {
        const inst = block.instrs.items[i];

        switch (inst) {
            .mov => |m| {
                if (vregOf(m.dst)) |dv| {
                    switch (m.src) {
                        .vreg => |sv| {
                            // mov v_r, v_s: наследуем scaled/addr а то сохраняем как копию
                            if (origin.get(sv)) |o| {
                                switch (o) {
                                    .scaled, .addr => try origin.put(dv, o),
                                    else => try origin.put(dv, .{ .copy = m.src }),
                                }
                            } else {
                                try origin.put(dv, .{ .copy = m.src });
                            }
                        },
                        .imm => |imm_val| {
                            try origin.put(dv, .{ .known_imm = @intCast(imm_val) });
                        },
                        else => _ = origin.remove(dv),
                    }
                }
                i += 1;
            },

            .shl => |s| {
                if (vregOf(s.dst)) |dv| {
                    const shift_amt = resolveShiftAmount(s.amount, &origin) orelse {
                        i += 1;
                        continue;
                    };
                    if (shift_amt >= 1 and shift_amt <= 3) {
                        const prev = origin.get(dv);
                        const source: MOperand = if (prev) |p| switch (p) {
                            .copy => |cp| cp,
                            .scaled => |sc| sc.source,
                            .addr => .{ .vreg = dv },
                            .known_imm => .{ .vreg = dv },
                        } else .{ .vreg = dv };
                        try origin.put(dv, .{ .scaled = .{
                            .source = source,
                            .scale = @as(u8, 1) << @intCast(shift_amt),
                        } });
                    }
                }
                i += 1;
            },

            .add => |m| {
                const dst_v = vregOf(m.dst) orelse {
                    i += 1;
                    continue;
                };

               //определяем источник значения это константа или другой vreg
                const src_imm: ?i32 = blk: {
                    if (m.src == .imm) {
                        break :blk @intCast(m.src.imm);
                    }
                    if (vregOf(m.src)) |sv| {
                        if (origin.get(sv)) |o| {
                            if (o == .known_imm) {
                                break :blk @intCast(o.known_imm);
                            }
                        }
                    }
                    break :blk null;
                };

                if (src_imm) |imm_val| {
                    // add v_r, known_imm сохраняем значение как смещение адреса
                    const prev = origin.get(dst_v);
                    if (prev) |p| {
                        switch (p) {
                            .scaled => {},
                            .addr => |a| {
                                try origin.put(dst_v, .{ .addr = .{
                                    .base = a.base,
                                    .index = a.index,
                                    .scale = a.scale,
                                    .disp = a.disp +% imm_val,
                                } });
                                i += 1;
                                continue;
                            },
                            .copy => |cp| {
                                if (vregOf(cp)) |base_vreg| {
                                    if (origin.get(base_vreg)) |base_origin| {
                                        if (base_origin == .known_imm) {
                                            try origin.put(dst_v, .{ .known_imm = @intCast(@as(i64, @intCast(base_origin.known_imm)) +% @as(i64, @intCast(imm_val))) });
                                            i += 1;
                                            continue;
                                        }
                                    }
                                }
                                try origin.put(dst_v, .{ .addr = .{
                                    .base = cp,
                                    .disp = imm_val,
                                } });
                                i += 1;
                                continue;
                            },
                            .known_imm => {
                               // константа плюс константа = константа
                                try origin.put(dst_v, .{ .known_imm = @intCast(@as(i64, @intCast(p.known_imm)) +% @as(i64, @intCast(imm_val))) });
                                i += 1;
                                continue;
                            },
                        }
                    }
                    _ = origin.remove(dst_v);
                    i += 1;
                    continue;
                }

                // add v_r, v_s: оба операнда — vreg, не удалось определить их как константы !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                if (vregOf(m.src)) |sv| {
                    const prev_dst = origin.get(dst_v);
                    const prev_src = origin.get(sv);

                    if (prev_src) |ps| {
                        switch (ps) {
                            .scaled => |sc| {
                                const base: MOperand = if (prev_dst) |pd| switch (pd) {
                                    .copy => |cp| cp,
                                    .addr => |a| a.base,
                                    else => m.dst,
                                } else m.dst;
                                try origin.put(dst_v, .{ .addr = .{
                                    .base = base,
                                    .index = sc.source,
                                    .scale = sc.scale,
                                    .disp = 0,
                                } });
                                i += 1;
                                continue;
                            },
                            .copy => {},
                            .addr => {},
                            .known_imm => unreachable,
                        }
                    }

                    _ = origin.remove(dst_v);
                }
                i += 1;
            },

            // Объединение LEA и ADD со смещением
            .lea => {
                if (i + 1 < block.instrs.items.len) {
                    const next = block.instrs.items[i + 1];
                    if (next == .add and next.add.src == .imm) {
                        const lea_dst = vregOf(block.instrs.items[i].lea.dst);
                        const add_dst = vregOf(next.add.dst);
                        if (lea_dst != null and lea_dst == add_dst) {
                            block.instrs.items[i].lea.disp +%= @intCast(next.add.src.imm);
                            _ = block.instrs.orderedRemove(i + 1);
                            continue;
                        }
                    }
                }
                i += 1;
            },

            else => i += 1,
        }
    }

    // Шаг 2 заменяем add v_r, #imm на LEA, если для v_r уже известен адрес
    i = 0;
    while (i < block.instrs.items.len) {
        const inst = block.instrs.items[i];
        if (inst == .add) {
            const a = inst.add;
           // заменяем только если источник непосредственная константа или vreg с известным константным значением
            const is_imm_src = if (a.src == .imm) true else blk: {
                if (vregOf(a.src)) |sv| {
                    if (origin.get(sv)) |o| {
                        if (o == .known_imm) break :blk true;
                    }
                }
                break :blk false;
            };
            if (is_imm_src) {
                if (vregOf(a.dst)) |dv| {
                    if (origin.get(dv)) |o| {
                        if (o == .addr) {
                            const addr = o.addr;
                            block.instrs.items[i] = .{ .lea = .{
                                .dst = a.dst,
                                .base = addr.base,
                                .index = addr.index,
                                .scale = addr.scale,
                                .disp = addr.disp,
                            } };
                        }
                    }
                }
            }
        }
        i += 1;
    }

   // аг 3 Заменяем add v_r, v_s на LEA, если для v_s известно масштабированное значение
    i = 0;
    while (i < block.instrs.items.len) {
        const inst = block.instrs.items[i];
        if (inst == .add) {
            const a = inst.add;
            if (vregOf(a.src)) |sv| {
                if (vregOf(a.dst)) |dv| {
                    if (origin.get(sv)) |o| {
                        if (o == .scaled) {
                            const sc = o.scaled;
                            const prev_dst = origin.get(dv);
                            const base: MOperand = if (prev_dst) |pd| switch (pd) {
                                .copy => |cp| cp,
                                .addr => |a2| a2.base,
                                else => a.dst,
                            } else a.dst;
                            block.instrs.items[i] = .{ .lea = .{
                                .dst = a.dst,
                                .base = base,
                                .index = sc.source,
                                .scale = sc.scale,
                                .disp = 0,
                            } };
                        }
                    }
                }
            }
        }
        i += 1;
    }
}

fn vregOf(op: MOperand) ?u32 {
    return switch (op) {
        .vreg => |v| v,
        else => null,
    };
}

fn resolveShiftAmount(amount: MOperand, origin: *const std.AutoHashMap(u32, Origin)) ?u8 {
    if (amount == .imm) {
        const v = amount.imm;
        if (v >= 0 and v <= 31) return @intCast(v);
        return null;
    }
    if (amount == .vreg) {
        if (origin.get(amount.vreg)) |o| {
            if (o == .known_imm) {
                const v: i64 = o.known_imm;
                if (v >= 0 and v <= 31) return @intCast(v);
            }
        }
    }
    return null;
}
