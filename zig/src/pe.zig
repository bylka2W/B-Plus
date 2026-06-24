const std = @import("std");

pub const section_rva: u32 = 0x1000;

pub const ResolvedExport = struct {
    name: []const u8,
    rva: u32,
};

pub fn write(allocator: std.mem.Allocator, code: []const u8, import_dir_rva: u32, idat_size: u32) ![]u8 {
    return writePE(allocator, code, import_dir_rva, idat_size, &.{}, false);
}

pub fn writeDll(allocator: std.mem.Allocator, code: []const u8, import_dir_rva: u32, idat_size: u32, exports: []const ResolvedExport) ![]u8 {
    return writePE(allocator, code, import_dir_rva, idat_size, exports, true);
}

fn writePE(allocator: std.mem.Allocator, code: []const u8, import_dir_rva: u32, idat_size: u32, exports: []const ResolvedExport, is_dll: bool) ![]u8 {
    const file_align: u32 = 0x200;
    const sect_align: u32 = 0x1000;

    var export_data: ?[]u8 = null;
    var export_dir_rva: u32 = 0;
    var export_dir_size: u32 = 0;
    if (is_dll and exports.len > 0) {
        const n = @as(u32, @intCast(exports.len));
        const base: u32 = 1;
        const edt_size: u32 = 40;
        const eat_size = n * 4;
        const enpt_size = n * 4;
        const eot_size = n * 2;
        var names_total: u32 = 0;
        for (exports) |e| names_total += @as(u32, @intCast(e.name.len)) + 1;
        const dll_name_size: u32 = 8;
        const total_export_size = edt_size + eat_size + enpt_size + eot_size + names_total + dll_name_size;

        var ed = std.ArrayList(u8).init(allocator);
        defer ed.deinit();
        try ed.ensureTotalCapacity(total_export_size);

        const edt_off: u32 = 0;
        const eat_off = edt_off + edt_size;
        const enpt_off = eat_off + eat_size;
        const eot_off = enpt_off + enpt_size;
        const names_off = eot_off + eot_size;
        const dll_name_off = names_off + names_total;

        const export_base_rva = section_rva + @as(u32, @intCast(code.len));

        // Sort exports by name for ENPT (GetProcAddress binary search requirement)
        var indices = try allocator.alloc(usize, n);
        defer allocator.free(indices);
        for (0..n) |i| indices[i] = i;
        const SortCtx = struct { exports: []const ResolvedExport };
        std.mem.sort(usize, indices, SortCtx{ .exports = exports }, struct {
            fn lessThan(ctx: SortCtx, a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx.exports[a].name, ctx.exports[b].name);
            }
        }.lessThan);

        // Name string offsets in sorted order
        var name_offs = try allocator.alloc(u32, n);
        defer allocator.free(name_offs);
        {
            var off: u32 = names_off;
            for (indices) |si| {
                name_offs[si] = off;
                off += @as(u32, @intCast(exports[si].name.len)) + 1;
            }
        }

        // Export Directory Table
        try ed.appendNTimes(0, 4);  // Characteristics
        try ed.appendNTimes(0, 4);  // TimeDateStamp
        try ed.appendNTimes(0, 2);  // MajorVersion
        try ed.appendNTimes(0, 2);  // MinorVersion
        const dll_name_rva = export_base_rva + dll_name_off;
        try ed.appendSlice(&@as([4]u8, @bitCast(dll_name_rva)));  // Name
        try ed.appendSlice(&@as([4]u8, @bitCast(base)));         // Base
        try ed.appendSlice(&@as([4]u8, @bitCast(n)));            // NumberOfFunctions
        try ed.appendSlice(&@as([4]u8, @bitCast(n)));            // NumberOfNames
        try ed.appendSlice(&@as([4]u8, @bitCast(export_base_rva + eat_off)));  // AddressOfFunctions
        try ed.appendSlice(&@as([4]u8, @bitCast(export_base_rva + enpt_off))); // AddressOfNames
        try ed.appendSlice(&@as([4]u8, @bitCast(export_base_rva + eot_off)));  // AddressOfNameOrdinals

        // Export Address Table (ordinal order)
        for (exports) |e| {
            try ed.appendSlice(&@as([4]u8, @bitCast(e.rva)));
        }

        // Export Name Pointer Table (sorted order)
        for (indices) |si| {
            try ed.appendSlice(&@as([4]u8, @bitCast(export_base_rva + name_offs[si])));
        }

        // Export Ordinal Table (sorted order, maps to EAT index)
        for (indices) |si| {
            try ed.appendSlice(&@as([2]u8, @bitCast(@as(u16, @intCast(si)))));
        }

        // Name strings (sorted order)
        while (ed.items.len < names_off) try ed.append(0);
        for (indices) |si| {
            try ed.appendSlice(exports[si].name);
            try ed.append(0);
        }
        // DLL name
        while (ed.items.len < dll_name_off) try ed.append(0);
        try ed.appendSlice("TSS.dll");
        try ed.append(0);

        export_data = try ed.toOwnedSlice();
        export_dir_rva = export_base_rva;
        export_dir_size = @as(u32, @intCast(export_data.?.len));
    }

    const total_code_size = @as(u32, @intCast(code.len)) + @as(u32, @intCast((export_data orelse @as([]u8, &.{})).len));
    const headers_size = alignUp(0x1B0, file_align);
    const raw_code_size = alignUp(total_code_size, file_align);
    const image_size = section_rva + alignUp(total_code_size, sect_align);

    var pe = std.ArrayList(u8).init(allocator);
    defer pe.deinit();

    // DOS Header
    try pe.appendSlice(&[_]u8{ 0x4D, 0x5A });
    try pe.appendNTimes(0, 58);
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, 0x80))));

    // DOS stub
    try pe.appendNTimes(0, 64);

    // PE signature
    try pe.appendSlice(&[_]u8{ 0x50, 0x45, 0x00, 0x00 });

    // IMAGE_FILE_HEADER
    const characteristics: u16 = if (is_dll) 0x2022 else 0x0022;
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 0x8664)))); // Machine
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 1))));      // NumberOfSections
    try pe.appendNTimes(0, 4);
    try pe.appendNTimes(0, 4);
    try pe.appendNTimes(0, 4);
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 0xF0))));   // SizeOfOptionalHeader
    try pe.appendSlice(&@as([2]u8, @bitCast(characteristics)));

    // IMAGE_OPTIONAL_HEADER64
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 0x020B))));
    try pe.appendNTimes(0, 2);
    try pe.appendNTimes(0, 4);
    try pe.appendNTimes(0, 4);
    try pe.appendNTimes(0, 4);
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, section_rva + 0))));
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, section_rva))));
    try pe.appendSlice(&@as([8]u8, @bitCast(@as(u64, 0x18000000))));
    try pe.appendSlice(&@as([4]u8, @bitCast(sect_align)));
    try pe.appendSlice(&@as([4]u8, @bitCast(file_align)));
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 6))));   // MajorOSVersion
    try pe.appendNTimes(0, 2);                                   // MinorOSVersion
    try pe.appendNTimes(0, 2);                                   // MajorImageVersion
    try pe.appendNTimes(0, 2);                                   // MinorImageVersion
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 6))));   // MajorSubsystemVersion
    try pe.appendNTimes(0, 2);                                   // MinorSubsystemVersion
    try pe.appendNTimes(0, 4);
    try pe.appendSlice(&@as([4]u8, @bitCast(image_size)));
    try pe.appendSlice(&@as([4]u8, @bitCast(headers_size)));
    try pe.appendNTimes(0, 4);
    const subsystem: u16 = if (is_dll) 2 else 3;
    try pe.appendSlice(&@as([2]u8, @bitCast(subsystem)));
    try pe.appendNTimes(0, 2);
    try pe.appendSlice(&@as([8]u8, @bitCast(@as(u64, 0x100000))));
    try pe.appendNTimes(0, 8);
    try pe.appendSlice(&@as([8]u8, @bitCast(@as(u64, 0x100000))));
    try pe.appendNTimes(0, 8);
    try pe.appendNTimes(0, 4);
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, 16))));

    // Data directories
    var imp_rva_val: u32 = 0;
    var imp_size_val: u32 = 0;
    if (import_dir_rva != 0) {
        imp_rva_val = section_rva + import_dir_rva;
        imp_size_val = idat_size;
    }
    if (is_dll and export_dir_size > 0) {
        try pe.appendSlice(&@as([4]u8, @bitCast(export_dir_rva)));
        try pe.appendSlice(&@as([4]u8, @bitCast(export_dir_size)));
    } else {
        try pe.appendNTimes(0, 8);
    }
    try pe.appendSlice(&@as([4]u8, @bitCast(imp_rva_val)));
    try pe.appendSlice(&@as([4]u8, @bitCast(imp_size_val)));
    for (0..14) |_| try pe.appendNTimes(0, 8);

    // Section table (.text)
    const sname = ".text\x00\x00\x00";
    try pe.appendSlice(sname);
    try pe.appendSlice(&@as([4]u8, @bitCast(total_code_size)));
    try pe.appendSlice(&@as([4]u8, @bitCast(section_rva)));
    try pe.appendSlice(&@as([4]u8, @bitCast(raw_code_size)));
    try pe.appendSlice(&@as([4]u8, @bitCast(headers_size)));
    try pe.appendNTimes(0, 4);
    try pe.appendNTimes(0, 4);
    try pe.appendNTimes(0, 2);
    try pe.appendNTimes(0, 2);
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, 0xE0000020))));

    while (pe.items.len < headers_size) try pe.append(0);

    try pe.appendSlice(code);
    if (export_data) |ed| {
        try pe.appendSlice(ed);
        allocator.free(ed);
    }

    while (pe.items.len < headers_size + raw_code_size) try pe.append(0);

    return pe.toOwnedSlice();
}

fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}
