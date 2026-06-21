import struct, sys

with open(sys.argv[1], 'rb') as f:
    d = f.read()

e = struct.unpack('<I', d[0x3C:0x40])[0]
fh = e + 4
num_sects = struct.unpack('<H', d[fh+2:fh+4])[0]
optsz = struct.unpack('<H', d[fh+16:fh+18])[0]
opt = fh + 20
dd = opt + 112
exp_rva = struct.unpack('<I', d[dd:dd+4])[0]
exp_size = struct.unpack('<I', d[dd+4:dd+8])[0]
print(f'Export RVA={exp_rva:#x} Size={exp_size}')

if exp_rva == 0:
    print('No exports')
    sys.exit(0)

sect = opt + optsz
for i in range(num_sects):
    sh = sect + i * 40
    name = d[sh:sh+8].rstrip(b'\x00').decode('ascii', errors='replace')
    va = struct.unpack('<I', d[sh+12:sh+16])[0]
    vs = struct.unpack('<I', d[sh+8:sh+12])[0]
    ro = struct.unpack('<I', d[sh+20:sh+24])[0]
    rs = struct.unpack('<I', d[sh+16:sh+20])[0]
    print(f'Section: {name} VAddr={va:#x} RawOff={ro:#x}')

    if va <= exp_rva < va + max(vs, rs):
        fo = ro + (exp_rva - va)
        edt = d[fo:fo+40]
        n_fn = struct.unpack('<I', edt[20:24])[0]
        n_nm = struct.unpack('<I', edt[24:28])[0]
        eat = struct.unpack('<I', edt[28:32])[0]
        ept = struct.unpack('<I', edt[32:36])[0]
        print(f'{n_fn} fns, {n_nm} names, EAT={eat:#x} ENPT={ept:#x}')

        for j in range(n_nm):
            fn_rva = struct.unpack('<I', d[fo + (eat - exp_rva) + j*4 : fo + (eat - exp_rva) + j*4 + 4])[0]
            npr = struct.unpack('<I', d[fo + (ept - exp_rva) + j*4 : fo + (ept - exp_rva) + j*4 + 4])[0]
            no = ro + (npr - va)
            s = d[no:].split(b'\x00')[0].decode('ascii', errors='replace')
            print(f'  {s}: RVA={fn_rva:#x}')
