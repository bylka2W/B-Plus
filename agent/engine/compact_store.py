"""
Compact Knowledge Store
=======================

Disk-backed, binary, deduplicated knowledge store for the B+ agent truth layer.

Design principles (per architecture review):
  * SOURCE stays only on disk (C:\\Users\\Local\\zig). We copy NO raw source text.
  * Every fact references an integer file_id, not a repeated path string.
  * Predicates / kinds / resolution / verification are dictionary-encoded to ints.
  * IDs are compact uint32 (SQLite INTEGER PK), not verbose hex strings.
  * Evidence stores ONLY (file_id, start, end, sha256). The actual source text is
    read from disk on demand. One evidence span is SHARED by all facts on that span.
  * Storage is SQLite (binary, disk-backed) => no 2GB RAM load; the runtime issues
    queries and only the matched records enter RAM, behind an LRU cache.
  * For cold storage / GitHub push the DB is gzip-compressed (<100MB/file limit).

Schema
------
  files(file_id, path, sha256, line_count, root, tier)
  dict_predicate(code, name)         # fact_type / predicate / relation_type
  dict_kind(code, name)               # symbol / concept kinds
  dict_resolution(code, name)         # RESOLVED / UNRESOLVED
  symbols(symbol_id, name, kind, file_id, line_start, line_end, signature, evidence_id)
  concepts(concept_id, name, kind, file_id, line_start, line_end, evidence_id)
  evidence(evidence_id, file_id, start, end, sha256)   # TEXT NEVER STORED
  facts(fact_id, file_id, fact_type, subject_id, object_id,
        object_value, line_start, line_end, evidence_id, resolution, verification)
  relations(relation_id, type, from_id, to_id, evidence_fact_ids)
"""
import os
import sys
import json
import gzip
import sqlite3
import hashlib
from collections import OrderedDict

VERIFIED = 1
RES = {"RESOLVED": 0, "UNRESOLVED": 1}


class CompactWriter:
    def __init__(self, db_path, root, tier="truth"):
        self.db_path = db_path
        self.root = root
        self.tier = tier
        self.conn = sqlite3.connect(db_path)
        self.c = self.conn.cursor()
        self._create()
        self._file_map = {}
        self._sym_map = {}
        self._concept_map = {}
        self._ev_map = {}
        self._pred_map = {}
        self._kind_map = {}
        self._res_map = {"RESOLVED": 0, "UNRESOLVED": 1}
        self._counters = {"facts": 0, "evidence": 0, "symbols": 0,
                          "relations": 0, "concepts": 0}

    def _create(self):
        self.c.executescript("""
        CREATE TABLE IF NOT EXISTS files(
            file_id INTEGER PRIMARY KEY, path TEXT, sha256 TEXT,
            line_count INTEGER, root TEXT, tier TEXT);
        CREATE TABLE IF NOT EXISTS dict_predicate(code INTEGER PRIMARY KEY, name TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS dict_kind(code INTEGER PRIMARY KEY, name TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS dict_resolution(code INTEGER PRIMARY KEY, name TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS symbols(
            symbol_id INTEGER PRIMARY KEY, name TEXT, kind INTEGER, file_id INTEGER,
            line_start INTEGER, line_end INTEGER, signature TEXT, evidence_id INTEGER);
        CREATE TABLE IF NOT EXISTS concepts(
            concept_id INTEGER PRIMARY KEY, name TEXT, kind INTEGER, file_id INTEGER,
            line_start INTEGER, line_end INTEGER, evidence_id INTEGER);
        CREATE TABLE IF NOT EXISTS evidence(
            evidence_id INTEGER PRIMARY KEY, file_id INTEGER, start INTEGER,
            end INTEGER, sha256 TEXT,
            UNIQUE(file_id, start, end));
        CREATE TABLE IF NOT EXISTS facts(
            fact_id INTEGER PRIMARY KEY, file_id INTEGER, fact_type INTEGER,
            subject_id INTEGER, object_id INTEGER, object_value TEXT,
            line_start INTEGER, line_end INTEGER, evidence_id INTEGER,
            resolution INTEGER, verification INTEGER);
        CREATE TABLE IF NOT EXISTS relations(
            relation_id INTEGER PRIMARY KEY, type INTEGER, from_id INTEGER,
            to_id INTEGER, evidence_fact_ids TEXT);
        CREATE INDEX IF NOT EXISTS ix_fact_file ON facts(file_id);
        CREATE INDEX IF NOT EXISTS ix_fact_type ON facts(fact_type);
        CREATE INDEX IF NOT EXISTS ix_fact_subj ON facts(subject_id);
        CREATE INDEX IF NOT EXISTS ix_sym_name ON symbols(name);
        CREATE INDEX IF NOT EXISTS ix_ev_file ON evidence(file_id);
        CREATE INDEX IF NOT EXISTS ix_rel_from ON relations(from_id);
        """)

    # ---- dictionary helpers ----
    def _pred(self, name):
        if name not in self._pred_map:
            code = len(self._pred_map) + 1
            self._pred_map[name] = code
            self.c.execute("INSERT INTO dict_predicate(code,name) VALUES(?,?)", (code, name))
        return self._pred_map[name]

    def _kind(self, name):
        if name not in self._kind_map:
            code = len(self._kind_map) + 1
            self._kind_map[name] = code
            self.c.execute("INSERT INTO dict_kind(code,name) VALUES(?,?)", (code, name))
        return self._kind_map[name]

    # ---- entity writers ----
    def add_file(self, path, sha256, line_count):
        if path in self._file_map:
            return self._file_map[path]
        self.c.execute("INSERT INTO files(path,sha256,line_count,root,tier) VALUES(?,?,?,?,?)",
                       (path, sha256, line_count, self.root, self.tier))
        fid = self.c.lastrowid
        self._file_map[path] = fid
        return fid

    def add_symbol(self, str_id, name, kind, file_id, ls, le, ev_str_id, signature=""):
        if str_id in self._sym_map:
            return self._sym_map[str_id]
        ev_id = self._ev_map.get(ev_str_id, 0) if ev_str_id else 0
        self.c.execute(
            "INSERT INTO symbols(name,kind,file_id,line_start,line_end,signature,evidence_id) "
            "VALUES(?,?,?,?,?,?,?)",
            (name, self._kind(kind), file_id, ls, le, signature, ev_id))
        sid = self.c.lastrowid
        self._sym_map[str_id] = sid
        self._counters["symbols"] += 1
        return sid

    def add_concept(self, str_id, name, kind, file_id, ls, le, ev_str_id):
        ev_id = self._ev_map.get(ev_str_id, 0) if ev_str_id else 0
        self.c.execute(
            "INSERT INTO concepts(name,kind,file_id,line_start,line_end,evidence_id) "
            "VALUES(?,?,?,?,?,?)",
            (name, self._kind(kind), file_id, ls, le, ev_id))
        cid = self.c.lastrowid
        if str_id:
            self._concept_map[str_id] = cid
        self._counters["concepts"] += 1
        return cid

    def add_evidence(self, str_id, file_id, start, end, sha256):
        if str_id in self._ev_map:
            return self._ev_map[str_id]
        self.c.execute(
            "INSERT OR IGNORE INTO evidence(file_id,start,end,sha256) VALUES(?,?,?,?)",
            (file_id, start, end, sha256))
        if self.c.rowcount > 0:
            eid = self.c.lastrowid
        else:
            # dedup collision: fetch existing id for (file_id,start,end)
            self.c.execute("SELECT evidence_id FROM evidence WHERE file_id=? AND start=? AND end=?",
                           (file_id, start, end))
            eid = self.c.fetchone()[0]
        self._ev_map[str_id] = eid
        self._counters["evidence"] += 1
        return eid

    def add_fact(self, fact_type, subject_str_id, object_str_id, object_value,
                 file_id, ls, le, ev_str_id, resolution, verification=VERIFIED):
        subj = self._sym_map.get(subject_str_id, 0) if subject_str_id else 0
        obj = self._sym_map.get(object_str_id, 0) if object_str_id else 0
        ev_id = self._ev_map.get(ev_str_id, 0) if ev_str_id else 0
        res = RES.get(resolution, 1)
        self.c.execute(
            "INSERT INTO facts(file_id,fact_type,subject_id,object_id,object_value,"
            "line_start,line_end,evidence_id,resolution,verification) "
            "VALUES(?,?,?,?,?,?,?,?,?,?)",
            (file_id, self._pred(fact_type), subj, obj, object_value, ls, le, ev_id, res, verification))
        self._counters["facts"] += 1
        return self.c.lastrowid

    def add_relation(self, rtype, from_str_id, to_str_id, evidence_fact_ids):
        def _resolve(s):
            if not s:
                return 0
            return self._sym_map.get(s, self._concept_map.get(s, 0))
        frm = _resolve(from_str_id)
        to = _resolve(to_str_id)
        self.c.execute(
            "INSERT INTO relations(type,from_id,to_id,evidence_fact_ids) VALUES(?,?,?,?)",
            (self._pred(rtype), frm, to, json.dumps(evidence_fact_ids)))
        self._counters["relations"] += 1
        return self.c.lastrowid

    def commit(self):
        self.conn.commit()

    def close(self):
        # ensure dict_resolution rows exist
        for name, code in self._res_map.items():
            self.c.execute("INSERT OR IGNORE INTO dict_resolution(code,name) VALUES(?,?)", (code, name))
        self.conn.commit()
        self.conn.close()

    def counters(self):
        return dict(self._counters)

    # ---- compress for cold storage (GitHub) ----
    def compress(self, out_path=None, level=9):
        if out_path is None:
            out_path = self.db_path + ".gz"
        with open(self.db_path, "rb") as f_in:
            data = f_in.read()
        with gzip.open(out_path, "wb", compresslevel=level) as f_out:
            f_out.write(data)
        return out_path, len(data), os.path.getsize(out_path)


class CompactReader:
    def __init__(self, db_path, max_cache_entries=20000):
        # accept .kdb, .kdb.gz, .kdb.zst (zstd handled if available)
        self.db_path = self._ensure_local(db_path)
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row
        self._load_dicts()
        self._lines_cache = OrderedDict()   # path -> lines, LRU
        self.max_cache_entries = max_cache_entries
        self._fact_cache = OrderedDict()
        self.max_fact_cache = max_cache_entries

    def _ensure_local(self, db_path):
        if db_path.endswith(".gz"):
            raw = db_path[:-3]
            if not os.path.exists(raw):
                with gzip.open(db_path, "rb") as f_in, open(raw, "wb") as f_out:
                    f_out.write(f_in.read())
            return raw
        return db_path

    def _load_dicts(self):
        self.pred_rev = {r["code"]: r["name"] for r in
                         self.conn.execute("SELECT code,name FROM dict_predicate")}
        self.kind_rev = {r["code"]: r["name"] for r in
                         self.conn.execute("SELECT code,name FROM dict_kind")}
        self.res_rev = {r["code"]: r["name"] for r in
                        self.conn.execute("SELECT code,name FROM dict_resolution")}
        self._file_by_id = {}
        for r in self.conn.execute("SELECT file_id,path FROM files"):
            self._file_by_id[r["file_id"]] = r["path"]

    # ---- LRU caches ----
    def _cache_lines(self, path):
        if path in self._lines_cache:
            self._lines_cache.move_to_end(path)
            return self._lines_cache[path]
        # readlines() keeps trailing newlines, matching the extractor's
        # sha convention: sha256("".join(lines[s-1:e])).
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        self._lines_cache[path] = lines
        if len(self._lines_cache) > self.max_cache_entries:
            self._lines_cache.popitem(last=False)
        return lines

    def get_file_path(self, file_id):
        return self._file_by_id.get(file_id)

    def get_evidence_text(self, evidence_id):
        """Recover the real source text for an evidence record from disk.

        The stored sha256 is computed over "".join(lines[s-1:e]) (the same
        convention used by the extractor), so we verify against that form; the
        display text uses newlines for readability.
        """
        row = self.conn.execute(
            "SELECT file_id,start,end,sha256 FROM evidence WHERE evidence_id=?",
            (evidence_id,)).fetchone()
        if not row:
            return None
        file_id, s, e, sha = row["file_id"], row["start"], row["end"], row["sha256"]
        path = self._file_by_id.get(file_id)
        if not path or not os.path.exists(path):
            return None
        lines = self._cache_lines(path)
        display = "\n".join(lines[s - 1:e])
        verify_text = "".join(lines[s - 1:e])
        actual = hashlib.sha256(verify_text.encode("utf-8", "replace")).hexdigest()
        return {"text": display, "sha256": actual, "match": actual == sha,
                "path": path, "start": s, "end": e}

    def query_facts(self, file_id=None, fact_type=None, subject_id=None, limit=5000):
        sql = "SELECT * FROM facts WHERE 1=1"
        args = []
        if file_id is not None:
            sql += " AND file_id=?"; args.append(file_id)
        if fact_type is not None:
            code = self._pred_code(fact_type)
            if code is None:
                return []
            sql += " AND fact_type=?"; args.append(code)
        if subject_id is not None:
            sql += " AND subject_id=?"; args.append(subject_id)
        sql += " LIMIT ?"; args.append(limit)
        out = []
        for r in self.conn.execute(sql, args):
            out.append(self._fact_row(r))
        return out

    def _pred_code(self, name):
        for code, n in self.pred_rev.items():
            if n == name:
                return code
        return None

    def _fact_row(self, r):
        return {
            "fact_id": r["fact_id"],
            "fact_type": self.pred_rev.get(r["fact_type"], "?"),
            "subject_id": r["subject_id"],
            "object_id": r["object_id"],
            "object_value": r["object_value"],
            "file_id": r["file_id"],
            "source_file": self._file_by_id.get(r["file_id"]),
            "line_start": r["line_start"],
            "line_end": r["line_end"],
            "evidence_id": r["evidence_id"],
            "resolution_status": self.res_rev.get(r["resolution"], "?"),
            "verification_status": "VERIFIED" if r["verification"] else "UNVERIFIED",
        }

    def _symbol_dict(self, r):
        return {"symbol_id": r["symbol_id"], "name": r["name"],
                "kind": self.kind_rev.get(r["kind"], "?"),
                "source_file": self._file_by_id.get(r["file_id"]),
                "file_id": r["file_id"], "line_start": r["line_start"],
                "line_end": r["line_end"], "signature": r["signature"]}

    def symbol_by_name(self, name, limit=50):
        out = []
        for r in self.conn.execute(
                "SELECT * FROM symbols WHERE name=? LIMIT ?", (name, limit)):
            out.append(self._symbol_dict(r))
        return out

    def symbol_by_substr(self, text, limit=40):
        out = []
        for r in self.conn.execute(
                "SELECT * FROM symbols WHERE name LIKE ? LIMIT ?",
                ("%" + text + "%", limit)):
            out.append(self._symbol_dict(r))
        return out

    def nested_symbols(self, sym, limit=200):
        """Symbols defined inside a container's span (its methods/fields)."""
        fid = sym.get("file_id")
        if fid is None:
            fid = self.file_id_by_path(sym.get("source_file", ""))
        if fid is None:
            return []
        ls, le = sym.get("line_start"), sym.get("line_end")
        out = []
        for r in self.conn.execute(
                "SELECT * FROM symbols WHERE file_id=? AND line_start>? AND line_end<=? LIMIT ?",
                (fid, ls, le, limit)):
            out.append(self._symbol_dict(r))
        return out

    def file_id_by_path(self, path):
        for fid, p in self._file_by_id.items():
            if p == path or path in p:
                return fid
        return None

    def query_facts_text(self, text, limit=200):
        out = []
        for r in self.conn.execute(
                "SELECT f.* FROM facts f WHERE f.object_value LIKE ? LIMIT ?",
                ("%" + text + "%", limit)):
            out.append(self._fact_row(r))
        return out

    def counts(self):
        return {
            "files": self.conn.execute("SELECT COUNT(*) FROM files").fetchone()[0],
            "symbols": self.conn.execute("SELECT COUNT(*) FROM symbols").fetchone()[0],
            "concepts": self.conn.execute("SELECT COUNT(*) FROM concepts").fetchone()[0],
            "evidence": self.conn.execute("SELECT COUNT(*) FROM evidence").fetchone()[0],
            "facts": self.conn.execute("SELECT COUNT(*) FROM facts").fetchone()[0],
            "relations": self.conn.execute("SELECT COUNT(*) FROM relations").fetchone()[0],
        }

    def close(self):
        self.conn.close()
