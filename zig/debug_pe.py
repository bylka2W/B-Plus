import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else "test_dll_v6.dll"
with open(path, 'rb') as f:
    d = f.read()

pe_off = struct.unpack_from('<I', d, 0x3C)[0]
print(f"PE sig at file offset 0x{pe_off:x}")

sig = d[pe_off:pe_off+4]
print(f"Sig: {sig}")

# IMAGE_FILE_HEADER at pe_off+4
fh = pe_off + 4
machine = struct.unpack_from('<H', d, fh)[0]
num_sects = struct.unpack_from('<H', d, fh+2)[0]
opt_hdr_sz = struct.unpack_from('<H', d, fh+16)[0]
char = struct.unpack_from('<H', d, fh+18)[0]
print(f"Machine: 0x{machine:04x}")
print(f"NumSections: {num_sects}")
print(f"SizeOfOptionalHeader: 0x{opt_hdr_sz:04x}")
print(f"Characteristics: 0x{char:04x}")

# Dump bytes around SizeOfOptionalHeader
for i in range(fh, fh+20):
    print(f"  0x{i:04x}: {d[i]:02x}")

print()
# Now look at optional header
opt = fh + 20
magic = struct.unpack_from('<H', d, opt)[0]
print(f"Optional header magic: 0x{magic:04x} at offset 0x{opt:x}")

if magic == 0x20B:
    # PE32+: export dir at opt + 112
    export_rva = struct.unpack_from('<I', d, opt + 112)[0]
    export_sz = struct.unpack_from('<I', d, opt + 116)[0]
    print(f"Export Dir (opt+112): RVA=0x{export_rva:x} Size=0x{export_sz:x}")

# Section headers
sect_off = opt + opt_hdr_sz
print(f"Section headers at file offset 0x{sect_off:x}")
for i in range(num_sects):
    so = sect_off + i * 40
    name = d[so:so+8].decode('ascii', errors='replace').rstrip('\x00').strip()
    vsz = struct.unpack_from('<I', d, so+8)[0]
    vrva = struct.unpack_from('<I', d, so+12)[0]
    raw_sz = struct.unpack_from('<I', d, so+16)[0]
    raw_ptr = struct.unpack_from('<I', d, so+20)[0]
    print(f"  [{i}] \"{name}\" VSize=0x{vsz:x} VRVA=0x{vrva:x} RawSize=0x{raw_sz:x} RawPtr=0x{raw_ptr:x}")
