import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else "test_dll_v6.dll"
with open(path, 'rb') as f:
    d = f.read()
print(f"File size: {len(d)}")

pe_off = struct.unpack_from('<I', d, 0x3C)[0]
print(f"PE signature at: 0x{pe_off:x}")

magic = struct.unpack_from('<H', d, pe_off + 24)[0]
print(f"Optional magic: 0x{magic:04x} (expected 0x020B)")

pe64 = pe_off + 24
# PE32+ data directory 0 (export) starts at offset 112 from optional header start
export_rva = struct.unpack_from('<I', d, pe64 + 112)[0]
export_sz = struct.unpack_from('<I', d, pe64 + 116)[0]
print(f"Export Dir (PE32+ offset 112/116): RVA=0x{export_rva:x} Size=0x{export_sz:x}")

# Also check offset 96/100 (legacy PE32 location)
export_rva2 = struct.unpack_from('<I', d, pe64 + 96)[0]
export_sz2 = struct.unpack_from('<I', d, pe64 + 100)[0]
print(f"Export Dir (at offset 96/100, PE32 style): RVA=0x{export_rva2:x} Size=0x{export_sz2:x}")

num_sects = struct.unpack_from('<H', d, pe_off + 6)[0]
opt_hdr_sz = struct.unpack_from('<H', d, pe_off + 16)[0]
print(f"Num sections: {num_sects}, OptHdrSize: 0x{opt_hdr_sz:x}")
sect_off = pe_off + 24 + opt_hdr_sz
for i in range(num_sects):
    name = d[sect_off:sect_off+8].decode('ascii', errors='replace').strip().strip('\x00')
    vrva = struct.unpack_from('<I', d, sect_off + 12)[0]
    vsz = struct.unpack_from('<I', d, sect_off + 8)[0]
    raw_ptr = struct.unpack_from('<I', d, sect_off + 20)[0]
    raw_sz = struct.unpack_from('<I', d, sect_off + 16)[0]
    print(f'  Section "{name}": VRVA=0x{vrva:x} VSize=0x{vsz:x} RawPtr=0x{raw_ptr:x} RawSize=0x{raw_sz:x}')
    sect_off += 40

idx = d.find(b'TSS_Init')
if idx >= 0:
    print(f'Found "TSS_Init" at file offset 0x{idx:x}')
else:
    print('NOT FOUND: TSS_Init')

idx2 = d.find(b'TSS.dll')
if idx2 >= 0:
    print(f'Found "TSS.dll" at file offset 0x{idx2:x}')
else:
    print('NOT FOUND: TSS.dll')

# Read the section header from pe.zig perspective
# section_rva is currently hardcoded at 0x1000 in pe.zig
# Let's check what raw offset corresponds to section RVA
# For single-section image with section_rva=0x1000, file offset = raw_ptr + (RVA - VRVA)
print(f'\nSection raw data range: 0x{raw_ptr:x} - 0x{raw_ptr + raw_sz:x}')
print(f'Section virtual range: 0x{vrva:x} - 0x{vrva + vsz:x}')
