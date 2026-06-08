const std = @import("std");

pub fn write(allocator: std.mem.Allocator, code: []const u8, import_dir_rva: u32, idat_size: u32) ![]u8 {
    const file_align: u32 = 0x200;
    const sect_align: u32 = 0x1000;
    const section_rva: u32 = 0x1000;

    const headers_size = alignUp(0x1B0, file_align);
    const raw_code_size = alignUp(@as(u32, @intCast(code.len)), file_align);
    const image_size = section_rva + alignUp(@as(u32, @intCast(code.len)), sect_align);

    var pe = std.ArrayList(u8).init(allocator);
    defer pe.deinit();

    // DOS Header
    try pe.appendSlice(&[_]u8{ 0x4D, 0x5A });
    try pe.appendNTimes(0, 58);
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, 0x80)))); // e_lfanew

    // DOS stub
    try pe.appendNTimes(0, 64);

    // PE signature
    try pe.appendSlice(&[_]u8{ 0x50, 0x45, 0x00, 0x00 });

    // IMAGE_FILE_HEADER
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 0x8664)))); // Machine = AMD64
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 1))));      // NumberOfSections
    try pe.appendNTimes(0, 4);                                     // TimeDateStamp
    try pe.appendNTimes(0, 4);                                     // PointerToSymbolTable
    try pe.appendNTimes(0, 4);                                     // NumberOfSymbols
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 0xF0))));   // SizeOfOptionalHeader
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 0x0022)))); // Characteristics

    // IMAGE_OPTIONAL_HEADER64
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 0x020B)))); // Magic = PE32+
    try pe.appendNTimes(0, 2);                                     // MajorLinkerVersion, MinorLinkerVersion
    try pe.appendNTimes(0, 4);                                     // SizeOfCode
    try pe.appendNTimes(0, 4);                                     // SizeOfInitializedData
    try pe.appendNTimes(0, 4);                                     // SizeOfUninitializedData
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, section_rva + 0)))); // AddressOfEntryPoint
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, section_rva))));     // BaseOfCode
    try pe.appendNTimes(0, 8);                                     // ImageBase
    try pe.appendSlice(&@as([4]u8, @bitCast(sect_align)));         // SectionAlignment
    try pe.appendSlice(&@as([4]u8, @bitCast(file_align)));         // FileAlignment
    try pe.appendNTimes(0, 2);                                     // MajorOperatingSystemVersion
    try pe.appendNTimes(0, 2);                                     // MinorOperatingSystemVersion
    try pe.appendNTimes(0, 2);                                     // MajorImageVersion
    try pe.appendNTimes(0, 2);                                     // MinorImageVersion
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 6))));       // MajorSubsystemVersion (Vista+)
    try pe.appendNTimes(0, 2);                                     // MinorSubsystemVersion
    try pe.appendNTimes(0, 4);                                     // Win32VersionValue
    try pe.appendSlice(&@as([4]u8, @bitCast(image_size)));         // SizeOfImage
    try pe.appendSlice(&@as([4]u8, @bitCast(headers_size)));       // SizeOfHeaders
    try pe.appendNTimes(0, 4);                                     // CheckSum
    try pe.appendSlice(&@as([2]u8, @bitCast(@as(u16, 3))));       // Subsystem = CONSOLE
    try pe.appendNTimes(0, 2);                                     // DllCharacteristics
    try pe.appendNTimes(0, 8);                                     // SizeOfStackReserve
    try pe.appendNTimes(0, 8);                                     // SizeOfStackCommit
    try pe.appendNTimes(0, 8);                                     // SizeOfHeapReserve
    try pe.appendNTimes(0, 8);                                     // SizeOfHeapCommit
    try pe.appendNTimes(0, 4);                                     // LoaderFlags
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, 16))));      // NumberOfRvaAndSizes

    // Data directories
    var import_rva: u32 = 0;
    var import_size: u32 = 0;
    if (import_dir_rva != 0) {
        import_rva = section_rva + import_dir_rva;
        import_size = idat_size;
    }
    try pe.appendNTimes(0, 8);  // Export
    try pe.appendSlice(&@as([4]u8, @bitCast(import_rva)));
    try pe.appendSlice(&@as([4]u8, @bitCast(import_size)));
    for (0..14) |_| try pe.appendNTimes(0, 8);

    // Section table (.text)
    const name = ".text\x00\x00\x00";
    try pe.appendSlice(name);
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, @intCast(code.len))))); // VirtualSize
    try pe.appendSlice(&@as([4]u8, @bitCast(section_rva)));                   // VirtualAddress
    try pe.appendSlice(&@as([4]u8, @bitCast(raw_code_size)));                 // SizeOfRawData
    try pe.appendSlice(&@as([4]u8, @bitCast(headers_size)));                  // PointerToRawData
    try pe.appendNTimes(0, 4);                                                // PointerToRelocations
    try pe.appendNTimes(0, 4);                                                // PointerToLinenumbers
    try pe.appendNTimes(0, 2);                                                // NumberOfRelocations
    try pe.appendNTimes(0, 2);                                                // NumberOfLinenumbers
    try pe.appendSlice(&@as([4]u8, @bitCast(@as(u32, 0x60000020))));          // CODE | EXECUTE | READ

    // Align headers
    while (pe.items.len < headers_size) try pe.append(0);

    // Write code
    try pe.appendSlice(code);

    // Zero-pad to raw size
    while (pe.items.len < headers_size + raw_code_size) try pe.append(0);

    return pe.toOwnedSlice();
}

fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}
