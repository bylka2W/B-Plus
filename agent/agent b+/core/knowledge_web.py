import os
import json
import time
import hashlib
from pathlib import Path
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple, Deque
from collections import deque

from core.state_tables import short_id

RELATION_SCORES = {
    "exact_source": 1.00,
    "compiler": 0.95,
    "ast": 0.90,
    "crossref": 0.85,
    "strong_inference": 0.75,
    "weak_inference": 0.50,
    "unsupported": 0.00,
}

EDGE_TYPES = {
    "defines", "contains", "calls", "called_by", "references",
    "depends_on", "returns", "accepts", "modifies", "tested_by",
    "related_to", "imports", "used_by", "tested_by",
}

NODE_KIND_RANK = {
    "file": 1, "module": 2, "concept": 3, "symbol": 4,
    "struct": 5, "enum": 6, "union": 7, "function": 8,
    "const": 9, "var": 10, "test": 11, "field": 12,
}


@dataclass
class WebNode:
    node_id: str
    name: str
    kind: str
    file_id: str = ""
    file_path: str = ""
    line_start: int = 0
    line_end: int = 0
    evidence_ids: List[str] = field(default_factory=list)
    facts: List[str] = field(default_factory=list)
    knowledge_level: int = 0
    canonical_entity_id: str = ""
    aliases: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict:
        return {
            "node_id": self.node_id, "name": self.name, "kind": self.kind,
            "file_id": self.file_id, "file_path": self.file_path,
            "line_start": self.line_start, "line_end": self.line_end,
            "evidence_ids": self.evidence_ids, "facts": self.facts,
            "knowledge_level": self.knowledge_level,
            "canonical_entity_id": self.canonical_entity_id,
            "aliases": self.aliases,
        }


@dataclass
class WebEdge:
    edge_id: str
    source_id: str
    target_id: str
    relation_type: str
    score: float
    confidence: float = 1.0
    status: str = "verified"
    evidence_id: str = ""
    source_chain: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict:
        return {
            "edge_id": self.edge_id, "source_id": self.source_id,
            "target_id": self.target_id, "relation_type": self.relation_type,
            "score": self.score, "confidence": self.confidence,
            "status": self.status, "evidence_id": self.evidence_id,
            "source_chain": self.source_chain,
        }


class KnowledgeWebEngine:
    def __init__(self, source_index=None, symbol_graph=None, knowledge=None):
        self.source_index = source_index
        self.symbol_graph = symbol_graph
        self.knowledge = knowledge

        self.nodes: Dict[str, WebNode] = {}
        self.edges: List[WebEdge] = {}
        self._edge_index: Dict[str, List[str]] = {}
        self._node_name_index: Dict[str, List[str]] = {}
        self._file_index: Dict[str, List[str]] = {}
        self._path_cache: Dict[Tuple[str, str], List[Dict]] = {}
        self._built = False
        self._concept_id_to_name: Dict[str, str] = {}
        self._concept_id_to_data: Dict[str, Dict] = {}
        self._fact_evidence_map: Dict[str, str] = {}
        self._canonical: Dict[str, str] = {}
        self._name_canonical: Dict[str, str] = {}
        self._fused: Set[str] = set()
        self._in_edge_index: Dict[str, List[str]] = {}
        self._entity_index: Dict[str, List[str]] = {}
        self._node_entity: Dict[str, str] = {}
        self._source_evidence: Dict[str, Dict] = {}

    def build(self):
        if self._built:
            return
        t0 = time.monotonic()

        self._build_nodes()
        self._fuse_concepts_into_symbols()
        self._attach_source_evidence()
        self._rebuild_indices()
        self._resolve_canonical_entities()
        self._build_edges()
        self._rebuild_indices()
        self._compute_knowledge_levels()

        self._built = True
        elapsed = time.monotonic() - t0
        print(f"  KnowledgeWeb: {len(self.nodes)} nodes, {len(self.edges)} edges "
              f"[{elapsed:.1f}s]")

    def save(self, path: str):
        data = {
            "nodes": {k: v.to_dict() for k, v in self.nodes.items()},
            "edges": [e.to_dict() for e in self.edges.values()],
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)

    def load(self, path: str):
        if not os.path.exists(path):
            return
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        self.nodes = {}
        for nid, nd in data.get("nodes", {}).items():
            self.nodes[nid] = WebNode(**{k: v for k, v in nd.items()
                                         if k in WebNode.__dataclass_fields__})
        self.edges = {}
        for ed in data.get("edges", []):
            e = WebEdge(**{k: v for k, v in ed.items()
                           if k in WebEdge.__dataclass_fields__})
            self.edges[e.edge_id] = e
        self._rebuild_indices()
        self._built = True

    # ---------------- node building ----------------

    def _build_nodes(self):
        if self.symbol_graph:
            for sym_id, node in self.symbol_graph.symbols.items():
                fpath = self.symbol_graph._file_paths.get(node.file_id, "")
                kind = self._normalize_kind(node.kind, node.name, node.module)
                wn = WebNode(
                    node_id=sym_id, name=node.name, kind=kind,
                    file_id=node.file_id, file_path=fpath,
                    line_start=node.line_start, line_end=node.line_end,
                )
                self.nodes[sym_id] = wn

        if self.source_index and hasattr(self.source_index, "files"):
            for fp in self.source_index.files:
                fid = short_id("FILE", fp)
                if fid not in self.nodes:
                    self.nodes[fid] = WebNode(
                        node_id=fid, name=os.path.basename(fp), kind="file",
                        file_id=fid, file_path=fp,
                    )

        if self.knowledge:
            self._concept_id_to_name = {}
            self._concept_id_to_data = {}
            self._fact_evidence_map = {}
            for f in self.knowledge.facts:
                if f.get("fact_id") and f.get("evidence_id"):
                    self._fact_evidence_map[f["fact_id"]] = f["evidence_id"]
            concept_items = getattr(self.knowledge, "concepts_by_id", None)
            if not concept_items:
                concept_items = {}
                for cname, cdata in getattr(self.knowledge, "concepts", {}).items():
                    if isinstance(cdata, dict) and cdata.get("concept_id"):
                        concept_items[cdata["concept_id"]] = cdata
            for cid, cdata in concept_items.items():
                if not isinstance(cdata, dict):
                    continue
                cname = cdata.get("name") or cid
                self._concept_id_to_name[cid] = cname
                self._concept_id_to_data[cid] = cdata
                nid = cid
                evidence_ids = []
                for fid in cdata.get("fact_ids", []) or []:
                    ev = self._fact_evidence_map.get(fid)
                    if ev and ev not in evidence_ids:
                        evidence_ids.append(ev)
                existing = self.nodes.get(nid)
                if existing is not None:
                    existing.name = existing.name or cname
                    existing.facts = existing.facts or list(cdata.get("fact_ids", []) or [])
                    if not existing.evidence_ids:
                        existing.evidence_ids = evidence_ids
                    continue
                self.nodes[nid] = WebNode(
                    node_id=nid, name=cname,
                    kind=self._normalize_kind(cdata.get("concept_type", "concept"),
                                              cname, ""),
                    file_id=cdata.get("file_id", ""),
                    evidence_ids=evidence_ids,
                    facts=cdata.get("fact_ids", []),
                )

    def _attach_source_evidence(self):
        """STEP 2: attach real source-backed definition evidence to every
        node that has a verifiable source location (file_id + line range).

        Evidence is derived purely from the actual .zig source text:
        file_id, line_start, line_end, text, sha256, a deterministic
        evidence_id and verification_status=VERIFIED. No synthetic facts
        are created. Nodes without a resolvable source location are left
        with their existing (KB) evidence only.
        """
        if not self.source_index or not hasattr(self.source_index, "files"):
            return
        files = self.source_index.files
        for nid, node in self.nodes.items():
            if not node.file_id or not node.file_path:
                continue
            if node.line_start < 1 or node.line_end < node.line_start:
                continue
            fpath = node.file_path
            fdata = files.get(fpath)
            if not fdata or "lines" not in fdata:
                continue
            lines = fdata["lines"]
            if node.line_end > len(lines):
                continue
            text = "\n".join(lines[node.line_start - 1: node.line_end])
            if not text.strip():
                continue
            sha = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()
            evid = short_id("EVID", node.file_id, node.line_start,
                            node.line_end, sha[:16])
            if evid not in node.evidence_ids:
                node.evidence_ids.append(evid)
            self._source_evidence[evid] = {
                "id": evid,
                "source_file": fpath,
                "file_id": node.file_id,
                "sha256": sha,
                "line_start": node.line_start,
                "line_end": node.line_end,
                "text": text,
                "kind": "source_definition",
                "verification_status": "VERIFIED",
            }

    def is_source_evidence_valid(self, evid: str) -> Tuple[bool, str]:
        """STEP 2.1: re-verify a source-derived evidence record against the
        live source tree. Returns (is_valid, reason). A record becomes invalid
        if the file is missing, the line range is out of bounds, or the source
        text no longer hashes to the recorded sha256 (tampered/changed source).
        """
        ev = self._source_evidence.get(evid)
        if ev is None:
            return (False, "unknown_evidence_id")
        fpath = ev["source_file"]
        fdata = self.source_index.files.get(fpath) if self.source_index else None
        if not fdata or "lines" not in fdata:
            return (False, "source_file_missing")
        lines = fdata["lines"]
        if ev["line_end"] > len(lines) or ev["line_start"] < 1:
            return (False, "line_range_out_of_bounds")
        text = "\n".join(lines[ev["line_start"] - 1: ev["line_end"]])
        sha = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()
        if sha != ev["sha256"]:
            return (False, "source_text_changed")
        return (True, "ok")

    def _normalize_kind(self, kind, name, module):
        k = (kind or "").lower()
        if k in ("fn", "function", "pub fn"):
            return "function"
        if k in ("struct", "const"):
            if k == "const" and name and name[:1].islower():
                return "const"
            return "struct"
        if k in ("enum", "union"):
            return k
        if k == "test":
            return "test"
        if k == "field":
            return "field"
        if k in ("module", "mod"):
            return "module"
        if k in ("import", "imports"):
            return "module"
        if k in ("var", "variable"):
            return "var"
        if k == "const":
            return "const"
        return "symbol"

    # ---------------- entity resolution / fusion ----------------

    def _resolve_id(self, nid):
        seen = set()
        while nid in self._canonical and nid not in seen:
            seen.add(nid)
            nid = self._canonical[nid]
        return nid

    def _fuse_concepts_into_symbols(self):
        if not self.knowledge:
            return

        by_name = {}
        for nid, node in self.nodes.items():
            if node.name:
                by_name.setdefault(node.name, []).append(node)

        for cdata in self._concept_id_to_data.values():
            cid = cdata.get("concept_id")
            cname = cdata.get("name") or cdata.get("canonical_name")
            if not cid or not cname:
                continue
            cands = [n for n in by_name.get(cname, [])
                     if n.node_id != cid and not n.name.startswith("run")]
            if not cands:
                continue

            canonical = self._best_canonical(cands, cdata)
            if canonical is None:
                continue

            self._canonical[cid] = canonical.node_id
            self._fused.add(cid)

            for ev in cdata.get("fact_ids", []) or []:
                eid = self._fact_evidence_map.get(ev)
                if eid and eid not in canonical.evidence_ids:
                    canonical.evidence_ids.append(eid)
            for fid in cdata.get("fact_ids", []) or []:
                if fid not in canonical.facts:
                    canonical.facts.append(fid)

            if canonical.kind in ("symbol", "struct", "CONSTANT", ""):
                canonical.kind = self._normalize_kind(
                    cdata.get("concept_type", canonical.kind), cname, "")

    def _best_canonical(self, cands, cdata):
        prefer = []
        ckind = (cdata.get("concept_type") or "").lower()
        cfile = cdata.get("file_id", "")
        for n in cands:
            score = 0
            if n.file_id and cfile and n.file_id == cfile:
                score += 3
            if ckind:
                nkind = self._normalize_kind(n.kind, n.name, "")
                if nkind == self._normalize_kind(ckind, n.name, ""):
                    score += 1
            if n.kind in ("struct", "enum", "union", "function"):
                score += 1
            prefer.append((score, n))
        prefer.sort(key=lambda x: -x[0])
        return prefer[0][1] if prefer else None

    def _resolve_canonical_entities(self):
        self._entity_index = {}
        self._node_entity = {}
        for nid, node in self.nodes.items():
            ent = self._derive_entity(nid, node)
            if not ent:
                continue
            node.canonical_entity_id = ent
            self._node_entity[nid] = ent
            self._entity_index.setdefault(ent, []).append(nid)
        for ent, nids in self._entity_index.items():
            for nid in nids:
                n = self.nodes.get(nid)
                if n is not None:
                    n.aliases = [x for x in nids if x != nid]

    def _derive_entity(self, nid, node):
        resolved = self._resolve_id(nid)
        if resolved != nid:
            rn = self.nodes.get(resolved)
            if rn is not None:
                node = rn
        if node.file_id:
            return short_id("ENT", node.file_id, node.name, node.kind)
        return short_id("ENT", node.name, node.kind)

    def entity_aliases(self, name_or_id: str) -> List[str]:
        nid = self._resolve_id(name_or_id)
        if nid not in self._node_entity:
            found = self._node_name_index.get(name_or_id, [])
            if found:
                nid = self._resolve_id(found[0])
        ent = self._node_entity.get(nid)
        return list(self._entity_index.get(ent, []))

    def resolve_entity(self, name_or_id: str) -> Optional[WebNode]:
        nid = self._resolve_id(name_or_id)
        if nid in self.nodes:
            return self.nodes[nid]
        found = self._node_name_index.get(name_or_id, [])
        for f in found:
            r = self._resolve_id(f)
            if r in self.nodes:
                return self.nodes[r]
        return None

    # ---------------- edge building ----------------

    def _build_edges(self):
        if self.symbol_graph:
            self._add_structural_edges()

        if self.knowledge:
            self._add_semantic_edges()

    def _add_structural_edges(self):
        for rel in self.symbol_graph.relations:
            rtype = rel.relation_type
            source = self.symbol_graph.symbols.get(rel.source_id)
            target = self.symbol_graph.symbols.get(rel.target_id)

            if rtype in ("calls",):
                if source and target:
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "calls", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:call_site"])
                    self._add_edge(target.symbol_id, source.symbol_id,
                                   "called_by", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:call_site"])
            elif rtype == "imports":
                if source and target:
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "imports", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:import"])
            elif rtype == "defined_in":
                if source and target:
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "contains", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:defined_in"])
            elif rtype == "use_type":
                if source and target:
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "uses", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:uses_type"])
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "depends_on", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:uses_type"])
                    self._add_edge(target.symbol_id, source.symbol_id,
                                   "used_by", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:uses_type"])
            elif rtype == "return_type":
                if source and target:
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "returns", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:return_type"])
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "depends_on", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:return_type"])
                    self._add_edge(target.symbol_id, source.symbol_id,
                                   "used_by", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:return_type"])
            elif rtype == "field_type":
                if source and target:
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "references", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:field_type"])
                    self._add_edge(source.symbol_id, target.symbol_id,
                                   "depends_on", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:field_type"])
                    self._add_edge(target.symbol_id, source.symbol_id,
                                   "used_by", score=RELATION_SCORES["ast"],
                                   evidence_id=rel.evidence_id, source_chain=["ast:field_type"])

        self._add_tested_by_edges()

    def _add_tested_by_edges(self):
        tests = {nid: n for nid, n in self.nodes.items()
                 if n.kind == "test"}
        if not tests:
            return
        file_symbols = {}
        for nid, n in self.nodes.items():
            if n.file_id and n.kind != "test":
                file_symbols.setdefault(n.file_id, []).append(n)

        for tnode in tests.values():
            same_file = file_symbols.get(tnode.file_id, []) if tnode.file_id else []
            for sym in same_file[:8]:
                if sym.node_id != tnode.node_id:
                    self._add_edge(sym.node_id, tnode.node_id, "tested_by",
                                   score=RELATION_SCORES["ast"],
                                   source_chain=["ast:test_colocated"])
            base = tnode.name
            if base.startswith("test_"):
                base = base[5:]
            for nid, n in self.nodes.items():
                if n.name == base and n.kind != "test" and n.node_id != tnode.node_id:
                    self._add_edge(n.node_id, tnode.node_id, "tested_by",
                                   score=RELATION_SCORES["ast"],
                                   source_chain=["ast:test_named"])

    def _add_semantic_edges(self):
        seen = set()
        for r in self.knowledge.relations:
            rid = r.get("relation_id", "")
            rtype = r.get("relation_type", "")
            from_c = r.get("from_concept", "")
            to_c = r.get("to_concept", "")
            status = r.get("verification_status", "UNSUPPORTED")
            fact_ids = r.get("evidence_fact_ids", [])
            edge_type = self._semantic_edge_type(rtype)
            evidence_id = self._facts_to_evidence(fact_ids)

            if status == "VERIFIED" and evidence_id:
                score = RELATION_SCORES["crossref"]
            elif status == "VERIFIED":
                score = RELATION_SCORES["strong_inference"]
            else:
                score = RELATION_SCORES["weak_inference"]

            key = (rid, from_c, to_c, edge_type)
            if key in seen:
                continue
            seen.add(key)

            source_id = self._resolve_concept_node(from_c)
            target_id = self._resolve_concept_node(to_c)
            if not source_id or not target_id:
                continue
            self._add_edge(source_id, target_id, edge_type,
                           score=score, evidence_id=evidence_id,
                           status=status.lower(), source_chain=["semantic_relations"])
            if edge_type == "calls":
                self._add_edge(target_id, source_id, "called_by",
                               score=score, evidence_id=evidence_id,
                               status=status.lower(), source_chain=["semantic_relations"])
            elif edge_type in ("uses", "references", "depends_on"):
                self._add_edge(target_id, source_id, "used_by",
                               score=score, evidence_id=evidence_id,
                               status=status.lower(), source_chain=["semantic_relations"])

    def _resolve_concept_node(self, cid):
        if not cid:
            return None
        if cid in self._canonical:
            return self._canonical[cid]
        if cid in self.nodes:
            return cid
        cdata = self._concept_id_to_data.get(cid)
        if not cdata:
            return None
        name = cdata.get("name") or cdata.get("canonical_name")
        if not name:
            return None
        nids = self._node_name_index.get(name, [])
        if nids:
            return nids[0]
        return cid

    def _resolve_named(self, name):
        ids = self._node_name_index.get(name, [])
        return ids[0] if ids else (name if name in self.nodes else None)

    def _concept_name(self, from_c, to_c=""):
        return self._concept_id_to_name.get(from_c)

    def _resolve_concept(self, cid):
        return self._concept_id_to_name.get(cid)

    def _facts_to_evidence(self, fact_ids):
        if not self._fact_evidence_map:
            if self.knowledge:
                for f in self.knowledge.facts:
                    if f.get("fact_id") and f.get("evidence_id"):
                        self._fact_evidence_map[f["fact_id"]] = f["evidence_id"]
        for fid in fact_ids or []:
            ev = self._fact_evidence_map.get(fid)
            if ev:
                return ev
        return ""

    def _semantic_edge_type(self, rtype):
        t = (rtype or "").lower()
        if t in ("defines", "define"):
            return "defines"
        if t in ("uses_type", "uses"):
            return "uses"
        if t in ("calls", "invokes"):
            return "calls"
        if t in ("references", "ref"):
            return "references"
        if t in ("depends_on", "depends"):
            return "depends_on"
        if t in ("tested_by", "tests"):
            return "tested_by"
        if t in ("belongs_to", "member_of"):
            return "belongs_to"
        if t in ("contains", "has"):
            return "contains"
        if t in ("imports", "import"):
            return "imports"
        if t in ("returns", "return_type"):
            return "returns"
        if t in ("accepts", "param", "parameter"):
            return "accepts"
        if t in ("modifies", "writes"):
            return "modifies"
        return "related_to"

    def _add_edge(self, source_id, target_id, rtype, score,
                  evidence_id="", status="verified", source_chain=None):
        if not source_id or not target_id or source_id == target_id:
            return
        eid = short_id("EDGE", source_id, target_id, rtype)
        if eid in self.edges:
            existing = self.edges[eid]
            if score > existing.score:
                existing.score = score
                existing.evidence_id = evidence_id or existing.evidence_id
            return
        self.edges[eid] = WebEdge(
            edge_id=eid, source_id=source_id, target_id=target_id,
            relation_type=rtype, score=score, evidence_id=evidence_id,
            status=status, source_chain=source_chain or [],
        )

    # ---------------- knowledge levels ----------------

    def _compute_knowledge_levels(self):
        for nid, node in self.nodes.items():
            level = self._knowledge_level(node)
            node.knowledge_level = level

    def _knowledge_level(self, node: WebNode) -> int:
        level = 0
        if node.name:
            level = 1

        if node.file_id or node.file_path:
            level = max(level, 2)

        node_edges = list(self._edge_index.get(node.node_id, []))
        node_edges += list(self._in_edge_index.get(node.node_id, []))
        if node_edges:
            level = max(level, 3)

        if node.evidence_ids:
            level = max(level, 4)

        structured = any(self.edges[e].relation_type in ("calls", "uses", "depends_on")
                         for e in node_edges)
        if structured:
            level = max(level, 5)

        if any(self.edges[e].relation_type == "tested_by" for e in node_edges):
            level = max(level, 6)

        if node.facts:
            level = max(level, 7)

        verified_edges = [e for e in node_edges
                          if self.edges[e].evidence_id and self.edges[e].score >= 0.85]
        if len(verified_edges) >= 2:
            level = max(level, 8)

        if len(node.evidence_ids) >= 2 or (len(verified_edges) >= 2 and node.facts):
            level = max(level, 9)

        if verified_edges and self._all_evidence_verified(node):
            level = max(level, 10)

        return level

    def _all_evidence_verified(self, node: WebNode) -> bool:
        if not node.evidence_ids:
            return False
        return True

    # ---------------- indices ----------------

    def _rebuild_indices(self):
        self._node_name_index = {}
        self._file_index = {}
        self._edge_index = {}
        self._in_edge_index = {}
        for nid, node in self.nodes.items():
            self._node_name_index.setdefault(node.name, []).append(nid)
            if node.file_id:
                self._file_index.setdefault(node.file_id, []).append(nid)
        for eid, edge in self.edges.items():
            self._edge_index.setdefault(edge.source_id, []).append(eid)
            self._in_edge_index.setdefault(edge.target_id, []).append(eid)

    def lookup(self, name: str) -> List[WebNode]:
        nids = self._node_name_index.get(name, [])
        out = []
        seen = set()
        for nid in nids:
            if nid in self._fused:
                continue
            n = self.nodes.get(nid)
            if not n or n.node_id in seen:
                continue
            seen.add(n.node_id)
            out.append(n)
        return out

    def neighbors(self, name: str, min_score: float = 0.0) -> List[Dict]:
        nodes = self.lookup(name)
        out = []
        for n in nodes[:2]:
            for eid in self._edge_index.get(n.node_id, []):
                e = self.edges[eid]
                if e.score < min_score:
                    continue
                target = self.nodes.get(e.target_id)
                if not target:
                    continue
                out.append({
                    "target": target.name, "kind": target.kind,
                    "relation": e.relation_type, "score": e.score,
                    "evidence_id": e.evidence_id, "file": target.file_path,
                    "knowledge_level": target.knowledge_level,
                })
            for e in self.edges.values():
                if e.target_id == n.node_id and e.score >= min_score:
                    src = self.nodes.get(e.source_id)
                    if not src or src.node_id == n.node_id:
                        continue
                    out.append({
                        "target": src.name, "kind": src.kind,
                        "relation": f"by_{e.relation_type}", "score": e.score,
                        "evidence_id": e.evidence_id, "file": src.file_path,
                        "knowledge_level": src.knowledge_level,
                    })
        seen = set()
        uniq = []
        for x in out:
            k = (x["target"], x["relation"])
            if k in seen:
                continue
            seen.add(k)
            uniq.append(x)
        return uniq

    def expand(self, name: str, depth: int = 2, min_score: float = 0.85) -> Dict:
        start_nodes = self.lookup(name)
        root_ids = {n.node_id for n in start_nodes}
        subgraph = {
            "root": name, "depth": depth, "min_score": min_score,
            "nodes": {}, "edges": [], "levels": {},
        }
        frontier = set(root_ids)
        visited = set()
        for d in range(0, depth + 1):
            if not frontier:
                break
            next_frontier = set()
            current = []
            for nid in frontier:
                if nid in visited:
                    continue
                visited.add(nid)
                node = self.nodes.get(nid)
                if not node:
                    continue
                subgraph["nodes"][nid] = node.to_dict()
                current.append(node)
                for eid in self._edge_index.get(nid, []):
                    e = self.edges[eid]
                    if e.score < min_score:
                        continue
                    subgraph["edges"].append(e.to_dict())
                    if e.target_id not in visited and d < depth:
                        tnode = self.nodes.get(e.target_id)
                        if tnode and tnode.node_id not in root_ids:
                            next_frontier.add(e.target_id)
            subgraph["levels"][d] = [n.name for n in current]
            frontier = next_frontier
        return subgraph

    def _collect_path_cache_targets(self):
        targets = []
        for nid, node in self._active_nodes().items():
            if node.knowledge_level >= 8 and node.name:
                targets.append(node.name)
        return targets[:50]

    def _resolve_path_target(self, name):
        nodes = self.lookup(name)
        return nodes[0] if nodes else None

    def shortest_path(self, a: str, b: str, min_score: float = 0.85) -> List[Dict]:
        key = (a, b)
        if key in self._path_cache:
            return self._path_cache[key]

        a_nodes = self.lookup(a)
        b_nodes = self.lookup(b)
        if not a_nodes or not b_nodes:
            self._path_cache[key] = []
            return []
        start = a_nodes[0].node_id
        goal = b_nodes[0].node_id

        prev = {}
        dist = {start: 0}
        q = deque([start])
        visited = set([start])
        found = False
        while q:
            cur = q.popleft()
            if cur == goal:
                found = True
                break
            for eid in self._edge_index.get(cur, []):
                e = self.edges[eid]
                if e.score < min_score:
                    continue
                nxt = e.target_id
                if nxt in visited:
                    continue
                visited.add(nxt)
                dist[nxt] = dist[cur] + 1
                prev[nxt] = (cur, e.relation_type, e.score)
                q.append(nxt)
                if nxt == goal:
                    found = True
                    q = deque()
                    break

        if not found:
            self._path_cache[key] = []
            return []

        path = []
        cur = goal
        while cur in prev:
            parent, rtype, score = prev[cur]
            path.append({"from": parent, "to": cur, "relation": rtype, "score": score})
            cur = parent
        path.reverse()

        names = []
        for step in path:
            snode = self.nodes.get(step["from"])
            tnode = self.nodes.get(step["to"])
            names.append({
                "from": snode.name if snode else step["from"],
                "to": tnode.name if tnode else step["to"],
                "relation": step["relation"], "score": step["score"],
            })
        self._path_cache[key] = names
        return names

    def precompute_paths(self, max_pairs: int = 200):
        targets = self._collect_path_cache_targets()
        count = 0
        for i in range(len(targets)):
            for j in range(i + 1, len(targets)):
                if count >= max_pairs:
                    return count
                if len(targets) > 60:
                    if (i * 7 + j) % 7 != 0:
                        continue
                self.shortest_path(targets[i], targets[j])
                count += 1
        return count

    # ---------------- coverage / quality ----------------

    def _active_nodes(self):
        return {nid: n for nid, n in self.nodes.items() if nid not in self._fused}

    def _top_level_nodes(self):
        TOP = {"struct", "enum", "union", "function", "const", "module", "test", "var"}
        return {nid: n for nid, n in self._active_nodes().items() if n.kind in TOP}

    def coverage_report(self) -> Dict:
        active = self._active_nodes()
        total = len(active)
        if total == 0:
            return self._empty_report()

        by_kind = {}
        for n in active.values():
            by_kind[n.kind] = by_kind.get(n.kind, 0) + 1

        def _pct(n):
            return round(n / total * 100, 1) if total else 0.0

        def _level_coverage(level_min):
            return _pct(sum(1 for n in active.values()
                            if n.knowledge_level >= level_min))

        def _has_evidence():
            return _pct(sum(1 for n in active.values() if n.evidence_ids))

        def _has_structured():
            return _pct(sum(1 for nid, n in active.items()
                            if any(self.edges[e].relation_type in
                                   ("calls", "uses", "depends_on")
                                   for e in self._edge_index.get(nid, []))))

        def _tested():
            return _pct(sum(1 for nid, n in active.items()
                            if any(self.edges[e].relation_type == "tested_by"
                                   for e in self._edge_index.get(nid, []))))

        verified_edges = sum(1 for e in self.edges.values()
                             if e.score >= 0.85 and e.evidence_id)
        evidence_edges = sum(1 for e in self.edges.values() if e.evidence_id)
        orphan_nodes = sum(1 for nid, n in active.items()
                           if not (self._edge_index.get(nid, []) or self._in_edge_index.get(nid, [])))
        dup_edges = self._count_duplicate_edges()

        edge_score_sum = sum(e.score for e in self.edges.values())
        edge_quality = round(edge_score_sum / max(len(self.edges), 1) * 100, 1)

        type_cov = _pct(sum(1 for n in active.values()
                            if n.kind in ("struct", "enum", "union", "field")))
        relation_cov = _pct(sum(1 for nid, n in active.items()
                                if self._edge_index.get(nid)
                                or self._in_edge_index.get(nid)))

        kq = self._knowledge_quality(
            definition=_level_coverage(4),
            structure=_level_coverage(5),
            type=type_cov,
            relation=relation_cov,
            call=_has_structured(),
            evidence=_has_evidence(),
            test=_tested(),
            semantic=_level_coverage(7),
            orphan_rate=round(orphan_nodes / total * 100, 1) if total else 0,
        )

        return {
            "total_nodes": total,
            "by_kind": by_kind,
            "total_edges": len(self.edges),
            "fused_aliases": len(self._fused),
            "coverage": {
                "definition": _level_coverage(4),
                "structure": _level_coverage(5),
                "type": type_cov,
                "relation": relation_cov,
                "call": _has_structured(),
                "evidence": _has_evidence(),
                "test": _tested(),
                "semantic": _level_coverage(7),
                "verified": _level_coverage(10),
            },
            "levels": {str(i): _level_coverage(i) for i in range(0, 11)},
            "quality": {
                "verified_edges": verified_edges,
                "evidence_edges": evidence_edges,
                "verified_edge_pct": round(verified_edges / max(len(self.edges), 1) * 100, 1),
                "edge_quality": edge_quality,
                "orphan_nodes": orphan_nodes,
                "orphan_rate": round(orphan_nodes / total * 100, 1) if total else 0,
                "duplicate_edges": dup_edges,
            },
            "kcs": kq,
        }

    def _count_duplicate_edges(self):
        keys = {}
        for e in self.edges.values():
            k = (e.source_id, e.target_id, e.relation_type)
            keys[k] = keys.get(k, 0) + 1
        return sum(1 for v in keys.values() if v > 1)

    def symbol_coverage_report(self) -> Dict:
        nodes = self._top_level_nodes()
        total = len(nodes)
        if total == 0:
            return {"total": 0, "knowledge_density": 0, "coverage": {}, "levels": {}}

        def _pct(n):
            return round(n / total * 100, 1) if total else 0.0

        def _lev(lmin):
            return _pct(sum(1 for n in nodes.values() if n.knowledge_level >= lmin))

        def _node_edges(nid):
            return list(self._edge_index.get(nid, [])) + list(self._in_edge_index.get(nid, []))

        def _node_has_any(nid):
            return bool(self._edge_index.get(nid) or self._in_edge_index.get(nid))

        def _node_has_edge_type(nid, types):
            return any(self.edges[e].relation_type in types for e in _node_edges(nid))

        def _node_has_verified(nid):
            return any(self.edges[e].evidence_id and self.edges[e].score >= 0.85
                       for e in _node_edges(nid))

        typed_kinds = ("struct", "enum", "union", "function", "const", "var")
        structured_types = ("contains", "belongs_to", "defines", "has")
        dependency_types = ("depends_on", "imports", "uses")
        callgraph_types = ("calls", "called_by")

        type_cov = _pct(sum(1 for n in nodes.values() if n.kind in typed_kinds))
        structure = _pct(sum(1 for nid, n in nodes.items()
                             if n.knowledge_level >= 3
                             or _node_has_edge_type(nid, structured_types)))
        relation = _pct(sum(1 for nid in nodes if _node_has_any(nid)))
        dependency = _pct(sum(1 for nid in nodes if _node_has_edge_type(nid, dependency_types)))
        callgraph = _pct(sum(1 for nid in nodes if _node_has_edge_type(nid, callgraph_types)))
        semantic = _lev(7)
        evidence = _pct(sum(1 for n in nodes.values() if n.evidence_ids))
        crossref = _pct(sum(1 for nid in nodes if _node_has_verified(nid)))
        test = _pct(sum(1 for nid in nodes if _node_has_edge_type(nid, ("tested_by",))))
        orphan = _pct(sum(1 for nid in nodes if not _node_has_any(nid)))

        density = self._knowledge_density(
            type=type_cov, structure=structure, relation=relation,
            dependency=dependency, callgraph=callgraph, semantic=semantic,
            evidence=evidence, crossref=crossref, test=test,
        )

        return {
            "total": total,
            "knowledge_density": density,
            "coverage": {
                "type": type_cov,
                "structure": structure,
                "relation": relation,
                "dependency": dependency,
                "callgraph": callgraph,
                "semantic": semantic,
                "evidence": evidence,
                "crossreference": crossref,
                "test": test,
            },
            "levels": {str(i): _lev(i) for i in range(0, 11)},
            "orphan_rate": orphan,
        }

    def integrity_report(self) -> Dict:
        if not self.knowledge:
            return {"dangling_relations": 0, "dangling_concepts": 0}
        known_ids = set(self._concept_id_to_data.keys())
        dangling = 0
        dangling_by_type = {}
        seen = set()
        for r in self.knowledge.relations:
            if not r.get("relation_id"):
                continue
            f = r.get("from_concept", "")
            t = r.get("to_concept", "")
            if not f or not t:
                continue
            if f in known_ids or t in known_ids:
                continue
            key = (f, t)
            if key in seen:
                continue
            seen.add(key)
            dangling += 1
            rtype = r.get("relation_type", "?.?")
            dangling_by_type[rtype] = dangling_by_type.get(rtype, 0) + 1
        return {
            "dangling_relations": dangling,
            "dangling_concepts": len(seen),
            "dangling_by_type": dict(sorted(dangling_by_type.items(), key=lambda x: -x[1])),
        }

    def _knowledge_density(self, type, structure, relation, dependency,
                           callgraph, semantic, evidence, crossref, test) -> float:
        w = {
            "type": 0.12, "structure": 0.12, "relation": 0.12,
            "dependency": 0.12, "callgraph": 0.12, "semantic": 0.12,
            "evidence": 0.10, "crossref": 0.10, "test": 0.08,
        }
        d = (
            type * w["type"] +
            structure * w["structure"] +
            relation * w["relation"] +
            dependency * w["dependency"] +
            callgraph * w["callgraph"] +
            semantic * w["semantic"] +
            evidence * w["evidence"] +
            crossref * w["crossref"] +
            test * w["test"]
        )
        return round(d, 1)

    def _empty_report(self):
        return {
            "total_nodes": 0, "by_kind": {}, "total_edges": 0,
            "coverage": {k: 0.0 for k in
                         ("definition", "structure", "type", "relation",
                          "call", "evidence", "test", "semantic", "verified")},
            "levels": {str(i): 0.0 for i in range(0, 11)},
            "quality": {"verified_edges": 0, "evidence_edges": 0,
                        "verified_edge_pct": 0, "edge_quality": 0,
                        "orphan_nodes": 0, "orphan_rate": 0, "duplicate_edges": 0},
            "kcs": self._knowledge_quality(0, 0, 0, 0, 0, 0, 0, 0, 0),
        }

    def _knowledge_quality(self, definition, structure, type, relation, call,
                           evidence, test, semantic, orphan_rate) -> float:
        w = {
            "definition": 0.15, "structure": 0.15, "type": 0.10,
            "relation": 0.15, "call": 0.15, "evidence": 0.10,
            "test": 0.05, "semantic": 0.05,
        }
        kq = (
            definition * w["definition"] +
            structure * w["structure"] +
            type * w["type"] +
            relation * w["relation"] +
            call * w["call"] +
            evidence * w["evidence"] +
            test * w["test"] +
            semantic * w["semantic"]
        )
        kq = round(kq, 1)
        penalty = round((orphan_rate / 100.0) * 10, 1)
        return round(max(0.0, kq - penalty), 1)

    def get_stats(self) -> Dict:
        return {
            "nodes": len(self.nodes),
            "edges": len(self.edges),
            "built": self._built,
            "path_cache": len(self._path_cache),
        }


def build_web(source_index, symbol_graph, knowledge, cache_path: str = "") -> KnowledgeWebEngine:
    web = KnowledgeWebEngine(source_index, symbol_graph, knowledge)
    if cache_path and os.path.exists(cache_path):
        web.load(cache_path)
        if len(web.nodes) > 0:
            return web
    web.build()
    if cache_path:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        try:
            web.save(cache_path)
        except Exception:
            pass
    return web
