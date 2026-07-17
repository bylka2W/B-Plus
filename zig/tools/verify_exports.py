import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else "test_dll_v6.dll"
with open(path, 'rb') as f:
    d = f.read()

pe_off = struct.unpack_from('<I', d, 0x3C)[0]
opt = pe_off + 4 + 20  # IMAGE_FILE_HEADER start + 20

export_rva = struct.unpack_from('<I', d, opt + 112)[0]
export_sz = struct.unpack_from('<I', d, opt + 116)[0]
print(f"Export Directory: RVA=0x{export_rva:x}, Size=0x{export_sz:x}")

# Section header
num_sects = struct.unpack_from('<H', d, pe_off + 4 + 2)[0]
opt_hdr_sz = struct.unpack_from('<H', d, pe_off + 4 + 16)[0]
sect_off = opt + opt_hdr_sz
for i in range(num_sects):
    si = sect_off + i * 40
    vrva = struct.unpack_from('<I', d, si + 12)[0]
    raw_ptr = struct.unpack_from('<I', d, si + 20)[0]
    print(f"  Section VRVA=0x{vrva:x}, RawPtr=0x{raw_ptr:x}")
    # Convert export RVA to file offset
    if export_rva >= vrva and export_rva < vrva + 0x100000:
        file_off = raw_ptr + (export_rva - vrva)
        print(f"  Export table at file offset 0x{file_off:x}")
        
        # Read EDT (40 bytes)
        edt = d[file_off:file_off + 40]
        n_fns = struct.unpack_from('<I', edt, 20)[0]
        n_names = struct.unpack_from('<I', edt, 24)[0]
        eat_rva = struct.unpack_from('<I', edt, 28)[0]
        enpt_rva = struct.unpack_from('<I', edt, 32)[0]
        eot_rva = struct.unpack_from('<I', edt, 36)[0]
        print(f"  NumberOfFunctions={n_fns}, NumberOfNames={n_names}")
        print(f"  EAT RVA=0x{eat_rva:x}, ENPT RVA=0x{enpt_rva:x}, EOT RVA=0x{eot_rva:x}")

        # Read EAT
        for j in range(min(n_fns, 10)):
            fn_off = raw_ptr + (eat_rva - vrva)
            fn_rva = struct.unpack_from('<I', d, fn_off + j * 4)[0]
            print(f"    Entry {j}: RVA=0x{fn_rva:x}")
        
        # Read ENPT
        for j in range(min(n_names, 10)):
            name_off = raw_ptr + (enpt_rva - vrva)
            name_rva = struct.unpack_from('<I', d, name_off + j * 4)[0]
            name_file_off = raw_ptr + (name_rva - vrva)
            name_str = d[name_file_off:d.find(b'\x00', name_file_off)].decode('ascii', errors='replace')
            print(f"    Name {j}: \"{name_str}\" (RVA=0x{name_rva:x})")
        
        # Read EOT
        for j in range(min(n_fns, 10)):
            eot_off = raw_ptr + (eot_rva - vrva)
            ord = struct.unpack_from('<H', d, eot_off + j * 2)[0]
            print(f"    Ordinal {j}: {ord}")

        # Verify prologue bytes for each export
        for j in range(min(n_fns, 10)):
            fn_rva = struct.unpack_from('<I', d, fn_off + j * 4)[0]
            fn_file_off = raw_ptr + (fn_rva - vrva)
            fn_bytes = d[fn_file_off:fn_file_off + 16]
            print(f"    Export {j} at 0x{fn_file_off:x}: {fn_bytes.hex()}")

print(f"\nDLL name string at file offset ...")
# Find DLL name in file
idx = d.find(b'TSS.dll')
if idx >= 0:
    print(f"  'TSS.dll' at 0x{idx:x}")
