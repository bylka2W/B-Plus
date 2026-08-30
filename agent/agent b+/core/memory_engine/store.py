"""Dense, cache-friendly storage for the B+ knowledge pyramid.

Layout (Structure-of-Arrays, no per-record Python objects):
  files:     f_path, f_type, f_hash, f_size(Q), f_mtime(Q), f_lines
  symbols:   s_file, s_name(str-id), s_kind(str-id), s_line0, s_line1
  relations: r_kind(str-id), r_from_type(B), r_from, r_to_type(B), r_to
  evidence:  e_file, e_sym(0=none), e_kind(str-id), e_line0, e_line1, e_hash

Strings live in a separate StringTable (see string_table.py). All numeric
columns are flat `array` buffers persisted as raw bytes and re-openable via
mmap for the COLD tier (no numpy; pure stdlib).
"""
import os
import struct
import mmap
from array import array

from core.memory_engine.string_table import StringTable

TYPE = {
    "id": "I", "line": "I", "flag": "B",
    "size": "Q", "time": "Q", "imp": "f",
}


class Column:
    def __init__(self, typecode):
        self.typecode = typecode
        self.a = array(typecode)

    def append(self, v):
        self.a.append(v)

    def __getitem__(self, i):
        return self.a[i]

    def __len__(self):
        return len(self.a)

    def save(self, f):
        f.write(struct.pack("<Q", len(self.a)))
        f.write(self.a.tobytes())

    def load_from(self, buf, off):
        (n,) = struct.unpack_from("<Q", buf, off)
        off += 8
        self.a = array(self.typecode)
        self.a.frombytes(buf[off:off + n * self.a.itemsize])
        return off + n * self.a.itemsize

    def mmap_from(self, mm, off):
        (n,) = struct.unpack_from("<Q", mm, off)
        off += 8
        self.a = array(self.typecode)
        self.a.frombytes(mm[off:off + n * self.a.itemsize])
        return off + n * self.a.itemsize


class MmapColumn:
    """Zero-copy column view over an mmap'd buffer (COLD tier).

    Single-element access does one struct.unpack_from on the mmap (no RAM copy);
    slicing copies only the requested range. This keeps the multi-million-row
    store on disk -- RAM holds only the MmapColumn metadata (offsets), not the
    data -- so the Knowledge Engine scales independently of source volume.
    """

    _FMT = {"I": "<I", "Q": "<Q", "B": "<B", "f": "<f"}

    def __init__(self, mm, off, typecode, count):
        self.mm = mm
        self.off = off
        self.typecode = typecode
        self.count = count
        self.itemsize = array(typecode).itemsize
        self.fmt = self._FMT[typecode]

    def __len__(self):
        return self.count

    def __getitem__(self, i):
        if isinstance(i, slice):
            start, stop, _ = i.indices(self.count)
            return array(self.typecode,
                          self.mm[self.off + start * self.itemsize:
                                  self.off + stop * self.itemsize])
        if i < 0:
            i += self.count
        if i < 0 or i >= self.count:
            raise IndexError("MmapColumn index out of range")
        (v,) = struct.unpack_from(self.fmt, self.mm, self.off + i * self.itemsize)
        return v


class MemoryStore:
    def __init__(self):
        self.st = StringTable()
        self.f_path = Column("I"); self.f_type = Column("I"); self.f_hash = Column("I")
        self.f_size = Column("Q"); self.f_mtime = Column("Q"); self.f_lines = Column("I")
        self.s_file = Column("I"); self.s_name = Column("I"); self.s_kind = Column("I")
        self.s_line0 = Column("I"); self.s_line1 = Column("I")
        self.r_kind = Column("I"); self.r_from_type = Column("B"); self.r_from = Column("I")
        self.r_to_type = Column("B"); self.r_to = Column("I")
        self.e_file = Column("I"); self.e_sym = Column("I"); self.e_kind = Column("I")
        self.e_line0 = Column("I"); self.e_line1 = Column("I"); self.e_hash = Column("I")
        # promotion bookkeeping (COLD/RAM)
        self.acc = array("Q")
        self.last = array("Q")
        self.imp = array("f")
        # line-offset index (SOURCE L4): per-file byte offsets of each line start
        self.loff = array("I")
        self.loff_start = array("I")
        self.loff_count = array("I")
        self._file_id = {}

    # ---- append API ----
    def add_file(self, path, ftype, fhash, size, mtime, lines):
        fid = len(self.f_path)
        self.f_path.append(self.st.get(path))
        self.f_type.append(self.st.get(ftype))
        self.f_hash.append(self.st.get(fhash))
        self.f_size.append(size)
        self.f_mtime.append(mtime)
        self.f_lines.append(lines)
        self._file_id[path] = fid
        # reserve a line-offset slot for EVERY file (global fid indexing);
        # text files fill it via add_line_offsets, binaries stay count=0.
        self.loff_start.append(len(self.loff))
        self.loff_count.append(0)
        return fid

    def add_symbol(self, fid, name, kind, line0, line1):
        sid = len(self.s_file)
        self.s_file.append(fid)
        self.s_name.append(self.st.get(name))
        self.s_kind.append(self.st.get(kind))
        self.s_line0.append(line0)
        self.s_line1.append(line1)
        self.acc.append(0); self.last.append(0); self.imp.append(0.0)
        return sid

    def add_relation(self, kind, ffrom, tfrom, fto, tto):
        self.r_kind.append(self.st.get(kind))
        self.r_from_type.append(ffrom); self.r_from.append(tfrom)
        self.r_to_type.append(fto); self.r_to.append(tto)

    def add_evidence(self, fid, sym, kind, line0, line1, hsh):
        self.e_file.append(fid)
        self.e_sym.append(sym)
        self.e_kind.append(self.st.get(kind))
        self.e_line0.append(line0)
        self.e_line1.append(line1)
        self.e_hash.append(self.st.get(hsh))

    def file_id(self, path):
        return self._file_id.get(path)

    def add_line_offsets(self, fid, offsets):
        """offsets: list of byte offsets of each line start (len = #lines)."""
        self.loff.extend(offsets)
        self.loff_count[fid] = len(offsets)

    def byte_span(self, fid, l0, l1):
        """Return (byte_off0, byte_off1) for 1-indexed line range [l0, l1]."""
        start = self.loff_start[fid]
        count = self.loff_count[fid]
        if count == 0:
            return 0, 0
        a = start + max(0, l0 - 1)
        off0 = self.loff[a] if a < len(self.loff) else 0
        off1 = self.f_size[fid] if l1 >= count else self.loff[start + l1]
        return off0, off1

    # ---- persistence ----
    def save(self, out_dir):
        os.makedirs(out_dir, exist_ok=True)
        self.st.save(os.path.join(out_dir, "strings.bin"))
        cols = [c for c in vars(self) if isinstance(c, str) and c not in ("st", "_file_id")]  # noop guard
        # explicit list (avoid st/_file_id)
        fields = [
            "f_path", "f_type", "f_hash", "f_size", "f_mtime", "f_lines",
            "s_file", "s_name", "s_kind", "s_line0", "s_line1",
            "r_kind", "r_from_type", "r_from", "r_to_type", "r_to",
            "e_file", "e_sym", "e_kind", "e_line0", "e_line1", "e_hash",
        ]
        with open(os.path.join(out_dir, "cols.bin"), "wb") as f:
            for name in fields:
                getattr(self, name).save(f)
        # promotion arrays
        with open(os.path.join(out_dir, "promo.bin"), "wb") as f:
            for col in (self.acc, self.last, self.imp, self.loff, self.loff_start, self.loff_count):
                f.write(struct.pack("<Q", len(col)))
                f.write(col.tobytes())

    @classmethod
    def load(cls, out_dir):
        """Load in COLD (disk/mmap-resident) mode: numeric columns are zero-copy
        MmapColumn views over cols.bin/promo.bin, and the StringTable is mmap'd
        with per-string byte offsets. Almost nothing is copied into RAM -- the
        working set stays on disk and only retrieved slices/page in on demand.
        """
        s = cls()
        s.st = StringTable.load(os.path.join(out_dir, "strings.bin"))
        fields = [
            "f_path", "f_type", "f_hash", "f_size", "f_mtime", "f_lines",
            "s_file", "s_name", "s_kind", "s_line0", "s_line1",
            "r_kind", "r_from_type", "r_from", "r_to_type", "r_to",
            "e_file", "e_sym", "e_kind", "e_line0", "e_line1", "e_hash",
        ]
        field_tc = {
            "f_path": "I", "f_type": "I", "f_hash": "I", "f_size": "Q", "f_mtime": "Q",
            "f_lines": "I", "s_file": "I", "s_name": "I", "s_kind": "I", "s_line0": "I",
            "s_line1": "I", "r_kind": "I", "r_from_type": "B", "r_from": "I",
            "r_to_type": "B", "r_to": "I", "e_file": "I", "e_sym": "I", "e_kind": "I",
            "e_line0": "I", "e_line1": "I", "e_hash": "I",
        }
        f = open(os.path.join(out_dir, "cols.bin"), "rb")
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        off = 0
        for name in fields:
            (n,) = struct.unpack_from("<Q", mm, off)
            off += 8
            setattr(s, name, MmapColumn(mm, off, field_tc[name], n))
            off += n * array(field_tc[name]).itemsize
        s._mm, s._file = mm, f
        pf = open(os.path.join(out_dir, "promo.bin"), "rb")
        pmm = mmap.mmap(pf.fileno(), 0, access=mmap.ACCESS_READ)
        poff = 0
        for name, tc in (("acc", "Q"), ("last", "Q"), ("imp", "f"),
                          ("loff", "I"), ("loff_start", "I"), ("loff_count", "I")):
            (n,) = struct.unpack_from("<Q", pmm, poff)
            poff += 8
            setattr(s, name, MmapColumn(pmm, poff, tc, n))
            poff += n * array(tc).itemsize
        s._pmm, s._pfile = pmm, pf
        # small path->id map (only ~4000 entries)
        s._file_id = {}
        for fid in range(len(s.f_path)):
            s._file_id[s.st[s.f_path[fid]]] = fid
        return s

    @classmethod
    def mmap_open(cls, out_dir):
        """Alias for the disk-resident loader (COLD tier)."""
        return cls.load(out_dir)
