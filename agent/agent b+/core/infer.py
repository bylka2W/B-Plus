"""Optimized inference engine for the B+ Zig agent model (eager + CUDA Graph).

Decode design (local RTX 5060 Ti, <=16GB):
  - static, pre-allocated KV cache written in place (no per-token torch.cat);
  - separate prefill() (whole prompt at once) and decode() (one token);
  - native grouped-query attention via F.scaled_dot_product_attention(...,
    enable_gqa=True): the 4 KV heads serve the 24 Q heads WITHOUT repeating/
    expanding K/V -> no extra memory traffic, no extra kernel;
  - a SINGLE static CUDA graph is captured for the one-token decode and replayed
    for every position. To keep the graph shape/address-static (so it can be
    reused), the only position-dependent quantities are passed as DATA:
      * RoPE freqs  -> a fixed-shape input tensor (filled outside the graph);
      * KV write slot -> index_copy_ with a scalar position tensor (data index);
      * attn_mask   -> fixed-shape tensor whose VALUES are rewritten outside.
    No torch.compile: we get a clean, correct baseline, then CUDA Graph removes
    per-token Python/kernel-launch overhead.

Model weights/architecture/vocab are never reduced. External knowledge is fed
by the agent loop via the prompt; this module only does reasoning + codegen.
"""
import torch
import torch.nn.functional as F
from core.model import apply_rotary_emb

_NEG = float("-inf")


class InferenceEngine:
    def __init__(self, model, dtype=torch.bfloat16, cache_len=2048, use_cuda_graph=True):
        self.model = model.cuda().eval().to(dtype)
        self.dtype = dtype
        self.cache_len = cache_len
        self.n_layers = model.n_layers
        self.n_heads = model.n_heads
        self.n_kv = model.n_kv_heads
        self.head_dim = model.head_dim
        self.cache = self.model.allocate_cache("cuda", dtype, max_seq=cache_len)
        self.freqs_cos_ref = model.layers[0].attention.freqs_cos
        self.freqs_sin_ref = model.layers[0].attention.freqs_sin
        self.pos = 0
        # static graph inputs (values change per step, addresses/shapes constant)
        self.mask = torch.full((1, 1, cache_len), _NEG, device="cuda", dtype=dtype)
        self.tok_in = torch.zeros(1, 1, dtype=torch.long, device="cuda")
        self.pos_t = torch.zeros((), dtype=torch.long, device="cuda")
        self.freqs_cos_in = torch.zeros(1, self.head_dim // 2, device="cuda", dtype=dtype)
        self.freqs_sin_in = torch.zeros(1, self.head_dim // 2, device="cuda", dtype=dtype)
        self._g = None
        if use_cuda_graph and torch.cuda.is_available():
            try:
                self._build_graph()
            except Exception as e:
                print(f"[infer] CUDA graph unavailable, eager decode: {e}")
                self._g = None

    # ---- one-token decode body (also used eagerly) ----
    def _step(self):
        x = self.model.tok_emb(self.tok_in)
        for i in range(self.n_layers):
            x = self._attn_layer(self.model.layers[i], x, self.freqs_cos_in, self.freqs_sin_in, self.pos_t, self.cache[i], self.mask)
        x = self.model.norm(x)
        return self.model.output(x)

    def _attn_layer(self, layer, x, freqs_cos, freqs_sin, pos_t, cache_i, mask):
        a = layer.attention
        h = layer.attention_norm(x)
        q = a.wq(h).view(1, 1, self.n_heads, self.head_dim).transpose(1, 2)
        k = a.wk(h).view(1, 1, self.n_kv, self.head_dim).transpose(1, 2)
        v = a.wv(h).view(1, 1, self.n_kv, self.head_dim).transpose(1, 2)
        q = apply_rotary_emb(q, freqs_cos, freqs_sin)
        k = apply_rotary_emb(k, freqs_cos, freqs_sin)
        # write the new K/V into the static cache at a DATA position (index_copy)
        cache_i[0].index_copy_(1, pos_t, k.squeeze(0))
        cache_i[1].index_copy_(1, pos_t, v.squeeze(0))
        k_full = cache_i[0].unsqueeze(0)
        v_full = cache_i[1].unsqueeze(0)
        out = F.scaled_dot_product_attention(q, k_full, v_full, attn_mask=mask, enable_gqa=True)
        out = out.transpose(1, 2).contiguous().view(1, 1, -1)
        x = x + a.wo(out)
        x = x + layer.ffn(layer.ffn_norm(x))
        return x

    def _build_graph(self):
        self.reset()
        self.tok_in.fill_(0)
        self.pos_t.fill_(0)
        self.freqs_cos_in.zero_()
        self.freqs_sin_in.zero_()
        self.mask.fill_(_NEG)
        self.mask[0, 0, :1] = 0.0
        with torch.no_grad():
            self._logits = self._step()
        self._g = torch.cuda.CUDAGraph()
        with torch.no_grad():
            with torch.cuda.graph(self._g):
                self._logits = self._step()

    def reset(self):
        self.pos = 0
        for k, v in self.cache:
            k.zero_()
            v.zero_()

    def _prefill_mask(self, T):
        m = torch.full((1, T, self.cache_len), _NEG, device="cuda", dtype=self.dtype)
        for i in range(T):
            m[0, i, :i + 1] = 0.0
        return m

    @torch.no_grad()
    def prefill(self, ids):
        T = ids.shape[1]
        if T > self.cache_len:
            raise ValueError(f"prompt {T} > cache_len {self.cache_len}")
        self.pos = T
        mask = self._prefill_mask(T)
        logits, _ = self.model(ids, start_pos=0, use_cache=True, cache=self.cache, attn_mask=mask)
        return logits[:, -1]

    @torch.no_grad()
    def decode(self, tok):
        pos = self.pos
        # fill graph inputs (values only)
        self.tok_in.copy_(tok)
        self.pos_t.fill_(pos)
        self.freqs_cos_in.copy_(self.freqs_cos_ref[pos:pos + 1])
        self.freqs_sin_in.copy_(self.freqs_sin_ref[pos:pos + 1])
        self.mask.fill_(_NEG)
        self.mask[0, 0, :pos + 1] = 0.0
        if self._g is not None:
            self._g.replay()
            self.pos += 1
            return self._logits[:, -1]
        logits = self._step()
        self.pos += 1
        return logits[:, -1]

    @torch.no_grad()
    def generate(self, ids, max_new_tokens=256, temperature=0.8, top_k=40):
        self.reset()
        last = self.prefill(ids)
        out = [ids]
        for _ in range(max_new_tokens):
            logits = last / max(temperature, 1e-6)
            if top_k > 0:
                v, _ = torch.topk(logits, min(top_k, logits.size(-1)))
                logits[logits < v[:, [-1]]] = float("-inf")
            probs = torch.softmax(logits, dim=-1)
            nxt = torch.multinomial(probs, num_samples=1)
            out.append(nxt)
            last = self.decode(nxt)
        return torch.cat(out, dim=1)
