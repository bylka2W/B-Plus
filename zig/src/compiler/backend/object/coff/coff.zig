const std = @import("std");
const mir = @import("../../mir/mir.zig");
const mir_x64 = @import("../../mir/mir_x64.zig");

pub const CoffResult = struct {
    bytes: std.ArrayList(u8),
};

pub fn emitCoff(mfuncs: []const mir.MFunction) !CoffResult {
    if (mfuncs.len == 0) return error.NoFunctions;
    const allocator = mfuncs[0].allocator;

    //вывод исходный код вместе со списком исправлений
    var emit = try mir_x64.emitCode(mfuncs);
    defer emit.code.deinit();
    defer emit.name_to_offset.deinit();
    defer emit.call_fixups.deinit();
    defer emit.func_starts.deinit();

    //строит таблицу символов и релокации для функций и вызовов

    var relocs = std.ArrayList(Reloc).init(allocator);
    defer relocs.deinit();

    var symbols = std.ArrayList(SymInfo).init(allocator);
    defer symbols.deinit();

    //карта индексов символов: имя = индекс
    var sym_map = std.StringHashMap(u32).init(allocator);
    defer sym_map.deinit();

    //добавляет символы функций из func_starts (функции MIR)
    for (emit.func_starts.items, 0..) |offset, i| {
        const name = mfuncs[i].name;
        try sym_map.put(name, @intCast(symbols.items.len));
        try symbols.append(.{
            .name = name,
            .offset = offset,
            .section_number = 1, // .text
            .storage_class = 0x02, // IMAGE_SYM_CLASS_EXTERNAL
        });
    }

    //добавляет символы runtime-заглушек, которых нет в func_starts
    {
        var iter = emit.name_to_offset.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const offset = entry.value_ptr.*;
            if (!sym_map.contains(name)) {
                const is_func_start = for (emit.func_starts.items) |fs| {
                    if (fs == offset) break true;
                } else false;
                if (!is_func_start) {
                    try sym_map.put(name, @intCast(symbols.items.len));
                    try symbols.append(.{
                        .name = name,
                        .offset = offset,
                        .section_number = 1,
                        .storage_class = 0x02,
                    });
                }
            }
        }
    }

    //преобразует исправления вызовов в релокации
    for (emit.call_fixups.items) |cf| 
    {
        const sym_idx = sym_map.get(cf.name) orelse {
            //добавляет внешний символ как неопределённый внешний символ
            const idx = @as(u32, @intCast(symbols.items.len));
            try sym_map.put(cf.name, idx);
            try symbols.append(.{
                .name = cf.name,
                .offset = 0,
                .section_number = 0, // undefined external
                .storage_class = 0x02, // IMAGE_SYM_CLASS_EXTERNAL
            });
            try relocs.append(.{
                .offset = cf.disp_pos,
                .sym_idx = idx,
                .type = .rel32,
            });
            continue;
        };
        try relocs.append(.{
            .offset = cf.disp_pos,
            .sym_idx = sym_idx,
            .type = .rel32,
        });
    }

    // Build output
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const num_sections: u16 = 1;
    const num_syms: u32 = @intCast(symbols.items.len);
    const num_relocs: u16 = @intCast(relocs.items.len);

    //рассчитывает расположение данных
    const file_hdr_size: u16 = 20;
    const section_tbl_size: u16 = 40;
    const raw_data_start: u32 = file_hdr_size + section_tbl_size;
    const raw_data_size = std.mem.alignForward(u32, @as(u32, @intCast(emit.code.items.len)), 4);
    const reloc_start = raw_data_start + raw_data_size;
    const symtab_start = reloc_start + @as(u32, @intCast(relocs.items.len)) * 10;

    //строит таблицу
    var strtab = std.ArrayList(u8).init(allocator);
    defer strtab.deinit();
    try strtab.appendNTimes(0, 4); // placeholder for length

    var name_offsets = std.ArrayList(u32).init(allocator);
    defer name_offsets.deinit();
    try name_offsets.appendNTimes(0, symbols.items.len);

    for (symbols.items, 0..) |si, i| {
        if (si.name.len > 8) {
            name_offsets.items[i] = @intCast(strtab.items.len);
            try strtab.appendSlice(si.name);
            try strtab.append(0);
        }
    }

    const strtab_len: u32 = @intCast(strtab.items.len);
    std.mem.writeInt(u32, strtab.items[0..4], strtab_len, .little);

    try writeFileHeader(&out, num_sections, num_syms, symtab_start);

    try writeSectionHeader(&out, ".text",
        raw_data_size, //размер виртуальных данных равен размеру исходных данных для объектного файла!!!!! ВАЖНННООООО 15август
        raw_data_size, 
        raw_data_start,
        reloc_start,
        num_relocs,
        0x60500020, //код - выполнение - чтение - инициализированные данные
    );

    try out.appendSlice(emit.code.items);
    try out.appendNTimes(0, raw_data_size - emit.code.items.len);

    for (relocs.items) |r| {
        try out.writer().writeInt(u32, @intCast(r.offset), .little);
        try out.writer().writeInt(u32, r.sym_idx, .little);
        try out.writer().writeInt(u16, @intFromEnum(r.type), .little);
    }

    for (symbols.items, 0..) |si, i| {
        var name_bytes: [8]u8 = .{0} ** 8;
        if (si.name.len > 8) {
            std.mem.writeInt(u32, name_bytes[0..4], 0, .little);
            std.mem.writeInt(u32, name_bytes[4..8], name_offsets.items[i], .little);
        } else {
            @memcpy(name_bytes[0..si.name.len], si.name);
        }
        try out.appendSlice(&name_bytes);
        try out.writer().writeInt(u32, @intCast(si.offset), .little);
        try out.writer().writeInt(i16, si.section_number, .little);
        try out.writer().writeInt(u16, 0, .little);
        try out.writer().writeByte(si.storage_class);
        try out.writer().writeByte(0);
    }

    try out.appendSlice(strtab.items);

    return .{ .bytes = out };
}

const RelocType = enum(u16) 
{
    rel32 = 0x0004, // IMAGE_REL_AMD64_REL32 !
};

const Reloc = struct 
{
    offset: usize,
    sym_idx: u32,
    type: RelocType,
};

const SymInfo = struct 
{
    name: []const u8,
    offset: usize,
    section_number: i16,
    storage_class: u8,
};

fn writeFileHeader(out: *std.ArrayList(u8), num_sections: u16, num_syms: u32, symtab_off: u32) !void {
    const w = out.writer();
    try w.writeInt(u16, 0x8664, .little);
    try w.writeInt(u16, num_sections, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, symtab_off, .little);
    try w.writeInt(u32, num_syms, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
}

fn writeSectionHeader(out: *std.ArrayList(u8), name: []const u8, virtual_size: u32, raw_size: u32, raw_data_off: u32, reloc_off: u32, num_relocs: u16, characteristics: u32) !void {
    const w = out.writer();
    var name_buf: [8]u8 = .{0} ** 8;
    @memcpy(name_buf[0..@min(name.len, 8)], name);
    try out.appendSlice(&name_buf);
    try w.writeInt(u32, virtual_size, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, raw_size, .little);
    try w.writeInt(u32, raw_data_off, .little);
    try w.writeInt(u32, reloc_off, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u16, num_relocs, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, characteristics, .little);
}
