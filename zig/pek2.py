import struct, sys

with open(sys.argv[1], 'rb') as f:
    d = f.read()

e = struct.unpack('<I', d[0x3C:0x40])[0]
fh = e + 4
ncpus = struct.unpack('<H', d[fh+2:fh+4])[0]
optsz = struct.unpack('<H', d[fh+16:fh+18])[0]

opt = fh + 20
dd = opt + 112

for i in range(16):
    rv = struct.unpack('<I', d[dd+i*8:dd+i*8+4])[0]
    sz = struct.unpack('<I', d[dd+i*8+4:dd+i*8+8])[0]
    names = ['Export','Import','Resource','Exception','Security','Reloc','Debug','Arch','GlobalPtr','TLS','LoadConfig','BoundImport','IAT','DelayImport','COM','Reserved']
    if rv or sz:
        print(f'  DD[{i}] {names[i]}: RVA={rv:#x} Size={sz}')
    else:
        print(f'  DD[{i}] {names[i]}: (empty)')

sect = opt + optsz
name = d[sect:sect+8].rstrip(b'\x00').decode('ascii', errors='replace')
vs = struct.unpack('<I', d[sect+8:sect+12])[0]
va = struct.unpack('<I', d[sect+12:sect+16])[0]
rs = struct.unpack('<I', d[sect+16:sect+20])[0]
ro = struct.unpack('<I', d[sect+20:sect+24])[0]
print(f'Section: {name} VAddr={va:#x} VSize={vs:#x} RawSize={rs:#x} RawOff={ro:#x}')
