"""Agent loop: Model Engine <-> KnowledgeQuery (Memory Engine) <-> Zig compiler.

Implements the L0 working-context architecture the user specified:

  query -> 20..100 candidates (KnowledgeQuery)
       -> reranker (canonical importance + query overlap)
       -> 5..15 FACTS (compact, FactCompressor) + 2..8 EVIDENCE spans (proof)
       -> compact context (cached in L0, tokenised once)
       -> 594M model (InferenceEngine, CUDA-Graph)
       -> Zig code
       -> zig ast-check / build   (external VERIFIER, not the model guessing)
       -> on error: retrieve the failing symbol's facts, feed back, regenerate
       -> repeat (bounded) until it compiles.

The model only ever sees the compact context -- never the whole C:\\B-Plus.
"""
import sys
import os
import re
import time

sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
import torch

from core.memory_engine.index import KnowledgeIndex
from core.memory_engine.knowledge_query import KnowledgeQuery, _norm
from core.memory_engine.facts import FactCompressor
from core.infer import InferenceEngine

try:
    from core.agent_runtime import ZigRunner
except Exception:
    ZigRunner = None

try:
    from knowledge.tokenizer import ZigTokenizer
except Exception:
    ZigTokenizer = None


def load_model_engine(vocab_size, cache_len=1024, ckpt_dir=None, use_cuda_graph=True):
    """Build the model from the canonical ModelConfig and load a checkpoint ONLY
    if a matching config sidecar says the shapes agree. This makes loading O(1)
    (no multi-GB torch.load just to discover a mismatch) and guarantees a 1280-dim
    checkpoint can never silently load into the 1440-dim model.

    Checkpoints produced by train_new_model.save_checkpoint() write a
    '<name>.config.json' sidecar; the loader only torch.load()s a .pt whose
    sidecar matches ModelConfig. Without a sidecar the checkpoint is refused.
    """
    if not torch.cuda.is_available():
        return None
    import json, glob
    from core.model import build_model_600m
    from core.model_config import ModelConfig
    cfg = ModelConfig(vocab_size=vocab_size, max_seq_len=256000)
    try:
        model = build_model_600m(cfg=cfg)
    except Exception as e:
        print(f"[agent] cannot build model: {e}")
        return None
    print(f"[agent] ModelConfig: dim={cfg.dim} layers={cfg.n_layers} "
          f"heads={cfg.n_heads} kv={cfg.n_kv_heads} ffn={cfg.hidden_dim} "
          f"vocab={cfg.vocab_size} (~{cfg.n_params//1_000_000}M params)")
    if ckpt_dir is None:
        ckpt_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "checkpoints")
    # find checkpoints that advertise a matching config via sidecar
    for sidecar in sorted(glob.glob(os.path.join(ckpt_dir, "*.config.json"))):
        try:
            with open(sidecar, encoding="utf-8") as f:
                cc = json.load(f)
        except Exception:
            continue
        ok, reason = cfg.matches_state_dict_shapes(cc)
        if not ok:
            print(f"[agent] skip {os.path.basename(sidecar)}: {reason}")
            continue
        pt = sidecar[: -len(".config.json")] + ".pt"
        if not os.path.exists(pt):
            continue
        try:
            ckpt = torch.load(pt, map_location="cpu", weights_only=False)
            sd = ckpt.get("model_state") or ckpt.get("state_dict") or ckpt
            model.load_state_dict(sd, strict=True)
            print(f"[agent] loaded checkpoint {os.path.basename(pt)} (config-verified)")
            return InferenceEngine(model, dtype=torch.bfloat16, cache_len=cache_len,
                                    use_cuda_graph=use_cuda_graph)
        except Exception as e:
            print(f"[agent] skip {os.path.basename(pt)}: {e}")
    print("[agent] no config-compatible checkpoint (no matching *.config.json sidecar). "
          "Train a 1440-dim checkpoint to load real weights; running uninitialised.")
    return None


class AgentLoop:
    def __init__(self, store, engine=None, tokenizer=None, zig_exe=None):
        self.store = store
        self.idx = KnowledgeIndex(store)
        self.idx.seed_hot_by_degree(5000)
        self.kq = KnowledgeQuery(self.idx)
        self.facts = FactCompressor(store, self.idx)
        self.engine = engine
        self.tokenizer = tokenizer
        self.zig = ZigRunner(zig_exe) if ZigRunner else None
        self.ctx_cache = {}  # L0: norm(query) -> tokenised compact context (ids)

    # ---- L0: rerank -> compact context -> cached tokens ----
    def retrieve_compact(self, query, top_facts=12, top_evidence=4, with_source=True):
        r = self.kq.retrieve(query, top_k=max(top_facts * 3, 24), with_source=with_source)
        ctx = self.facts.compact_context(r["matches"], top_facts, top_evidence,
                                         self.kq if with_source else None)
        return ctx, r

    def cached_context_ids(self, query, **kw):
        nq = _norm(query)
        if nq in self.ctx_cache:
            return self.ctx_cache[nq]
        ctx, _ = self.retrieve_compact(query, **kw)
        ids = self.tokenizer.encode(ctx) if self.tokenizer else []
        self.ctx_cache[nq] = ids
        return ids

    # ---- generation ----
    def _extract_zig(self, text):
        m = re.search(r"```zig\s*(.*?)```", text, re.S)
        if m:
            return m.group(1).strip()
        # fallback: first pub fn / const block
        if "pub fn" in text or "const std" in text:
            return text.strip()
        return text.strip()

    def generate_zig(self, task, max_iters=4, max_new_tokens=320, temperature=0.6, top_k=30):
        SYS = ("You are a Zig codegen agent. Use the retrieved knowledge (compact facts) "
               "and produce ONLY a Zig snippet in ```zig fenced blocks. Do not guess APIs "
               "that are not listed. Keep it minimal and compilable.\n\n")
        ctx_ids = self.cached_context_ids(task) if self.tokenizer else []
        history = []
        last_code = ""
        for it in range(max_iters):
            prompt = SYS
            if ctx_ids:
                prompt += self.tokenizer.decode(ctx_ids) + "\n"
            prompt += f"\nTask: {task}\n"
            for fb in history[-2:]:
                prompt += "\n" + fb + "\n"
            prompt += "\n```zig\n"
            if self.engine is None or self.tokenizer is None:
                # knowledge-only fallback: cannot generate; stop
                return {"ok": False, "code": "", "error": "no model engine",
                        "iters": it, "history": history}
            ids = self.tokenizer.encode(prompt)
            t0 = time.monotonic()
            out = self.engine.generate(torch.tensor([ids], dtype=torch.long, device="cuda"),
                                        max_new_tokens=max_new_tokens,
                                        temperature=temperature, top_k=top_k)
            new_ids = out[0].tolist()[len(ids):]
            gen = self.tokenizer.decode(new_ids)
            code = self._extract_zig(prompt + gen)
            last_code = code
            if self.zig is None:
                return {"ok": True, "code": code, "error": "", "iters": it + 1, "history": history}
            ok, msg, dur = self.zig.syntax_check_code(code)
            history.append(f"Compiler error: {msg}" if not ok else "Compiler: OK")
            if ok:
                return {"ok": True, "code": code, "error": "", "iters": it + 1,
                        "verify_ms": dur, "history": history}
            # feedback: pull facts for symbols mentioned in the error
            fb = self._error_feedback(msg)
            if fb:
                history.append("Relevant knowledge:\n" + fb)
        return {"ok": False, "code": last_code, "error": "max iters", "iters": max_iters,
                "history": history}

    def _error_feedback(self, msg, limit=3):
        names = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", msg))
        known = [n for n in names if n in self.idx.name_to_syms]
        lines = []
        for n in known[:limit]:
            sids = self.idx.name_to_syms[n][:1]
            lines.append(self.facts.fact_text(sids[0]))
        return "\n".join(lines)
