const std = @import("std");
const LinkOptions = @import("linker.zig").LinkOptions;
const pe = @import("../compiler/backend/object/pe/pe.zig");

const ObjSym = struct {
    name: []const u8,
    value: u32,
    section_number: i16,
    storage_class: u8,
};

const ObjReloc = struct {
    offset: u32,
    sym_idx: u32,
    rtype: u16,
};

const ObjectData = struct {
    code: []const u8,
    symbols: []ObjSym,
    symmap: []i32,
    relocs: []ObjReloc,
};

const Def = struct { obj_idx: usize, value: u32 };

fn ensureOutputDeletable(output_path: []const u8) void {
    std.fs.cwd().deleteFile(output_path) catch {};
    if (std.fs.cwd().openFile(output_path, .{ .mode = .read_only })) |f| {
        f.close();
        const base = std.fs.path.basename(output_path);
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "taskkill", "/F", "/IM", base, "/T" },
        }) catch {
            std.debug.print("note: could not kill {s} (still running)\n", .{base});
            return;
        };
        std.time.sleep(250 * std.time.ns_per_ms);
        std.fs.cwd().deleteFile(output_path) catch {};
        std.time.sleep(50 * std.time.ns_per_ms);
        std.fs.cwd().deleteFile(output_path) catch {};
    } else |_| {}
}

fn readSymbolName(strtab: []const u8, name_field: *const [8]u8) ![]const u8 {
    if (name_field[0] == 0) {
        const offset = std.mem.readInt(u32, name_field[4..8], .little);
        if (offset >= strtab.len) return error.CorruptObject;
        var end: usize = offset;
        while (end < strtab.len and strtab[end] != 0) : (end += 1) {}
        return strtab[offset..end];
    }
    var end: usize = 0;
    while (end < 8 and name_field[end] != 0) : (end += 1) {}
    return name_field[0..end];
}

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) !ObjectData {
    if (bytes.len < 20) return error.CorruptObject;
    const machine = std.mem.readInt(u16, bytes[0..2], .little);
    if (machine != 0x8664) return error.NotX64Object;
    const num_sections = std.mem.readInt(u16, bytes[2..4], .little);
    const ptr_symtab = std.mem.readInt(u32, bytes[8..12], .little);
    const num_syms = std.mem.readInt(u32, bytes[12..16], .little);
    if (num_sections < 1) return error.NoSections;

    const sec_hdr: usize = 20;
    if (sec_hdr + 40 > bytes.len) return error.CorruptObject;
    const raw_size = std.mem.readInt(u32, bytes[sec_hdr + 16 ..][0..4], .little);
    const raw_off = std.mem.readInt(u32, bytes[sec_hdr + 20 ..][0..4], .little);
    const reloc_off = std.mem.readInt(u32, bytes[sec_hdr + 24 ..][0..4], .little);
    const num_relocs = std.mem.readInt(u16, bytes[sec_hdr + 32 ..][0..2], .little);

    if (raw_off + raw_size > bytes.len) return error.CorruptObject;
    const code = try allocator.dupe(u8, bytes[raw_off .. raw_off + raw_size]);

    const relocs = try allocator.alloc(ObjReloc, num_relocs);
    if (reloc_off + @as(usize, num_relocs) * 10 > bytes.len) return error.CorruptObject;
    for (0..num_relocs) |i| {
        const r = reloc_off + i * 10;
        relocs[i] = .{
            .offset = std.mem.readInt(u32, bytes[r..][0..4], .little),
            .sym_idx = std.mem.readInt(u32, bytes[r + 4 ..][0..4], .little),
            .rtype = std.mem.readInt(u16, bytes[r + 8 ..][0..2], .little),
        };
    }

    var strtab: []const u8 = &.{};
    if (ptr_symtab != 0 and ptr_symtab + @as(usize, num_syms) * 18 + 4 <= bytes.len) {
        const str_start = @as(usize, ptr_symtab) + @as(usize, num_syms) * 18;
        const sz = std.mem.readInt(u32, bytes[str_start..][0..4], .little);
        if (sz >= 4 and str_start + sz <= bytes.len) {
            strtab = bytes[str_start .. str_start + sz];
        }
    }

    var symbols = std.ArrayList(ObjSym).init(allocator);
    errdefer symbols.deinit();
    const symmap = try allocator.alloc(i32, num_syms);
    @memset(symmap, -1);
    var i: usize = 0;
    while (i < num_syms) : (i += 1) {
        const sp = @as(usize, ptr_symtab) + i * 18;
        if (sp + 18 > bytes.len) return error.CorruptObject;
        var name_field: [8]u8 = undefined;
        @memcpy(&name_field, bytes[sp..][0..8]);
        const name = try readSymbolName(strtab, &name_field);
        const value = std.mem.readInt(u32, bytes[sp + 8 ..][0..4], .little);
        const sec_no = std.mem.readInt(i16, bytes[sp + 12 ..][0..2], .little);
        const storage = bytes[sp + 16];
        const num_aux = bytes[sp + 17];
        symmap[i] = @intCast(symbols.items.len);
        try symbols.append(.{
            .name = try allocator.dupe(u8, name),
            .value = value,
            .section_number = sec_no,
            .storage_class = storage,
        });
        i += num_aux;
    }

    return .{ .code = code, .symbols = try symbols.toOwnedSlice(), .symmap = symmap, .relocs = relocs };
}

pub fn linkSelfHost(allocator: std.mem.Allocator, options: LinkOptions) !void {
    if (options.mode == .dll) return error.UnsupportedPlatform;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var objs = std.ArrayList(ObjectData).init(aa);
    errdefer objs.deinit();

    {
        const bytes = try std.fs.cwd().readFileAlloc(aa, options.obj_path, 256 * 1024 * 1024);
        try objs.append(try parseObject(aa, bytes));
    }
    for (options.extra_objs) |p| {
        const bytes = try std.fs.cwd().readFileAlloc(aa, p, 256 * 1024 * 1024);
        try objs.append(try parseObject(aa, bytes));
    }

    var defs = std.StringHashMap(Def).init(aa);
    for (objs.items, 0..) |o, oi| {
        for (o.symbols) |s| {
            if (s.section_number > 0 and s.name.len > 0 and !defs.contains(s.name)) {
                try defs.put(s.name, .{ .obj_idx = oi, .value = s.value });
            }
        }
    }

    var text_starts = try aa.alloc(u32, objs.items.len);
    var text_total: u32 = 0;
    for (objs.items, 0..) |o, oi| {
        text_starts[oi] = text_total;
        text_total +|= @as(u32, @intCast(o.code.len));
    }

    var import_seen = std.StringHashMap(void).init(aa);
    var import_list = std.ArrayList([]const u8).init(aa);
    for (objs.items) |o| {
        for (o.symbols) |s| {
            if (s.section_number == 0 and s.storage_class == 0x02 and s.name.len > 0) {
                if (defs.contains(s.name)) continue;
                if (!import_seen.contains(s.name)) {
                    try import_seen.put(s.name, {});
                    try import_list.append(s.name);
                }
            }
        }
    }
    std.mem.sort([]const u8, import_list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const entry_def = defs.get(options.entry) orelse return error.EntrySymbolNotFound;
    const entry_point_rva = text_starts[entry_def.obj_idx] + entry_def.value;

    const text_pad = std.mem.alignForward(u32, text_total, 8);
    const n_imp = import_list.items.len;
    const dll_name = "kernel32.dll";

    const idt_off: u32 = 0;
    const ilt_off: u32 = 40;
    const iat_off: u32 = ilt_off + @as(u32, @intCast((n_imp + 1) * 8));
    const thunk_off: u32 = iat_off + @as(u32, @intCast(n_imp * 8));
    var hint_off: u32 = thunk_off + @as(u32, @intCast(n_imp * 6));
    hint_off = (hint_off + 1) & ~@as(u32, 1);

    var hint_start = try aa.alloc(u32, n_imp);
    var dll_name_off: u32 = hint_off;
    {
        var cur = hint_off;
        for (import_list.items, 0..) |nm, i| {
            hint_start[i] = cur;
            cur +|= 2 + @as(u32, @intCast(nm.len)) + 1;
        }
        dll_name_off = cur;
    }
    const imp_total = dll_name_off + @as(u32, @intCast(dll_name.len + 1));

    var imp = std.ArrayList(u8).init(aa);
    try imp.appendNTimes(0, imp_total);

    const section_addend = pe.section_rva;

    for (import_list.items, 0..) |nm, i| {
        const hn_rva: u64 = @as(u64, section_addend + text_pad + hint_start[i]);
        std.mem.writeInt(u64, imp.items[ilt_off + i * 8 ..][0..8], hn_rva, .little);
        std.mem.writeInt(u64, imp.items[iat_off + i * 8 ..][0..8], hn_rva, .little);
        const thunk_pos = @as(usize, thunk_off) + i * 6;
        imp.items[thunk_pos] = 0xFF;
        imp.items[thunk_pos + 1] = 0x25;
        const iat_sec = @as(i64, @as(u32, iat_off + @as(u32, @intCast(i * 8))));
        const disp32: i32 = @intCast(iat_sec - @as(i64, @as(u32, @intCast(thunk_pos)) + 6));
        std.mem.writeInt(i32, imp.items[thunk_pos + 2 ..][0..4], disp32, .little);
        std.mem.writeInt(u16, imp.items[hint_start[i] ..][0..2], 0, .little);
        @memcpy(imp.items[@as(usize, hint_start[i]) + 2 ..][0..nm.len], nm);
        imp.items[@as(usize, hint_start[i]) + 2 + nm.len] = 0;
    }

    std.mem.writeInt(u32, imp.items[idt_off + 0 ..][0..4], section_addend + text_pad + ilt_off, .little);
    std.mem.writeInt(u32, imp.items[idt_off + 12 ..][0..4], section_addend + text_pad + dll_name_off, .little);
    std.mem.writeInt(u32, imp.items[idt_off + 16 ..][0..4], section_addend + text_pad + iat_off, .little);
    @memcpy(imp.items[dll_name_off ..][0..dll_name.len], dll_name);
    imp.items[dll_name_off + dll_name.len] = 0;

    var code = std.ArrayList(u8).init(aa);
    for (objs.items) |o| try code.appendSlice(o.code);
    try code.appendNTimes(0, @intCast(text_pad - text_total));
    try code.appendSlice(imp.items);

    for (objs.items, 0..) |o, oi| {
        for (o.relocs) |r| {
            if (r.rtype != 0x0004) continue;
            const field_off = @as(usize, text_starts[oi]) + r.offset;
            if (field_off + 4 > code.items.len) return error.CorruptRelocation;
            if (r.sym_idx >= o.symmap.len) return error.CorruptRelocation;
            const mi = o.symmap[r.sym_idx];
            if (mi < 0 or @as(usize, @intCast(mi)) >= o.symbols.len) return error.CorruptRelocation;
            const sym = o.symbols[@intCast(mi)];
            const target_off: u32 = blk: {
                if (sym.section_number > 0) {
                    break :blk text_starts[oi] + sym.value;
                }
                if (defs.get(sym.name)) |d| {
                    break :blk text_starts[d.obj_idx] + d.value;
                }
                if (sym.name.len > 0) {
                    const idx = findImport(import_list.items, sym.name) orelse {
                        return error.UnresolvedSymbol;
                    };
                    break :blk text_pad + thunk_off + @as(u32, @intCast(idx * 6));
                }
                return error.UnresolvedSymbol;
            };
            const disp: i32 = @intCast(@as(i64, target_off) - @as(i64, @as(u32, @intCast(field_off)) + 4));
            std.mem.writeInt(i32, code.items[field_off..][0..4], disp, .little);
        }
    }

    const exe_bytes = try pe.write(aa, code.items, text_pad, imp_total, entry_point_rva);

    ensureOutputDeletable(options.output_path);
    try std.fs.cwd().writeFile(.{ .sub_path = options.output_path, .data = exe_bytes });
}

fn findImport(imports: []const []const u8, name: []const u8) ?usize {
    for (imports, 0..) |im, i| {
        if (std.mem.eql(u8, im, name)) return i;
    }
    return null;
}
