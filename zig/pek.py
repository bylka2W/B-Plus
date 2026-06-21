import struct, sys

with open(sys.argv[1], 'rb') as f:
    d = f.read()

e = struct.unpack('<I', d[0x3C:0x40])[0]
print(f'PE sig at: {e:#x}')

fh = e + 4  # file header starts after PE signature
ncpus = struct.unpack('<H', d[fh+2:fh+4])[0]
optsz = struct.unpack('<H', d[fh+16:fh+18])[0]
print(f'Sections: {ncpus}, OptHdrSize: {optsz}')

opt = fh + 20  # optional header starts after file header
dd = opt + 112
for i in range(16):
    rv = struct.unpack('<I', d[dd+i*8:dd+i*8+4])[0]
    sz = struct.unpack('<I', d[dd+i*8+4:dd+i*8+8])[0]
    if rv or sz:
        print(f'  DD[{i}]: RVA={rv:#x} Size={sz}')

sect = opt + optsz
name = d[sect:sect+8].rstrip(b'\x00').decode()
vs = struct.unpack('<I', d[sect+8:sect+12])[0]
va = struct.unpack('<I', d[sect+12:sect+16])[0]
rs = struct.unpack('<I', d[sect+16:sect+20])[0]
ro = struct.unpack('<I', d[sect+20:sect+24])[0]
print(f'Section: {name} VAddr={va:#x} VSize={vs:#x} RawSize={rs:#x} RawOff={ro:#x}')
print(f'File size: {len(d)}')
