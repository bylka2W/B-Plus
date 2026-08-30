"""String interning table (dense string -> uint32 id).

Replaces millions of repeated Python strings with a single uint32 id, keeping
the hot RAM index small and cache-friendly. Persisted as a length-prefixed
UTF-8 blob (no numpy, pure stdlib).
"""
import mmap
import struct
from array import array


class StringTable:
    def __init__(self):
        self._list = []
        self._map = {}

    def get(self, s):
        if s is None:
            s = ""
        s = str(s)
        i = self._map.get(s)
        if i is not None:
            return i
        i = len(self._list)
        self._list.append(s)
        self._map[s] = i
        return i

    def lookup(self, s):
        """Return the id for s, or -1 if not present (does NOT intern)."""
        if s is None:
            s = ""
        i = self._map.get(str(s))
        return i if i is not None else -1

    def __getitem__(self, i):
        if self._mm is not None:
            a = self.offsets[i]
            b = self.offsets[i + 1]
            # offsets point at the 4-byte length prefix; the string bytes follow it
            return self._mm[a + 4:b].decode("utf-8", "replace")
        return self._list[i]

    def __len__(self):
        if self._mm is not None:
            return len(self.offsets) - 1
        return len(self._list)

    def save(self, path):
        with open(path, "wb") as f:
            for s in self._list:
                b = s.encode("utf-8", "replace")
                f.write(struct.pack("<I", len(b)))
                f.write(b)

    @classmethod
    def load(cls, path):
        """COLD (disk-resident) load: only a per-string byte-offset array lives in
        RAM; the actual strings are read from the mmap on demand. This removes the
        multi-million-entry Python string list / _map dict from RAM entirely."""
        t = cls()
        f = open(path, "rb")
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        t._mm = mm
        t._file = f
        t._list = []
        t._map = {}
        offs = [0]
        pos = 0
        n = len(mm)
        while pos < n:
            (ln,) = struct.unpack_from("<I", mm, pos)
            pos += 4 + ln
            offs.append(pos)
        t.offsets = array("I", offs)
        return t

    def lookup(self, s):
        # only meaningful in build (intern) mode; runtime uses index binary search
        if self._mm is not None:
            return -1
        if s is None:
            s = ""
        i = self._map.get(str(s))
        return i if i is not None else -1
