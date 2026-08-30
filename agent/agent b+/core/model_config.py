"""Single source of truth for the model architecture.

Every component that touches the model -- model construction, the tokenizer's
vocab size, and the checkpoint loader -- MUST derive its dimensions from a single
ModelConfig instance. This guarantees:

    checkpoint  <->  model config  <->  tokenizer

stay consistent. The loader refuses to load a checkpoint whose tensor shapes do
not match this config (no more silent 1280-dim weights inside a 1440-dim model).
"""
from dataclasses import dataclass


@dataclass
class ModelConfig:
    vocab_size: int = 31934
    dim: int = 1440
    n_layers: int = 24
    n_heads: int = 24
    n_kv_heads: int = 4
    max_seq_len: int = 256000
    hidden_dim: int = 3840

    @property
    def head_dim(self):
        return self.dim // self.n_heads

    @property
    def n_params(self):
        # rough parameter count (excludes buffers) for reporting
        d = self.dim; L = self.n_layers; h = self.hidden_dim
        V = self.vocab_size; kv = self.n_kv_heads
        per_layer = (d * (self.n_heads * self.head_dim)    # wq
                     + 2 * d * (kv * self.head_dim)        # wk, wv
                     + (self.n_heads * self.head_dim) * d  # wo
                     + 2 * d                               # attn_norm + ffn_norm
                     + d * (2 * h) + h * d)                # SwiGLU (w13: d->2h, w2: h->d)
        return V * d + L * per_layer + V * d + 2 * d       # tok_emb + layers + output + final_norm

    def matches_state_dict(self, sd):
        """Return (ok, reason) by inspecting tensor shapes in a state_dict."""
        def shape(key):
            t = sd.get(key)
            return tuple(t.shape) if t is not None else None
        q = shape("layers.0.attention.wq.weight")
        if q is None:
            return False, "no layers.0.attention.wq.weight in checkpoint"
        d_model = q[1]
        if d_model != self.dim:
            return False, f"checkpoint d_model={d_model} != config dim={self.dim}"
        kv = shape("layers.0.attention.wk.weight")
        if kv is not None and kv[1] != kv[0] and (kv[1] // self.head_dim) != self.n_kv_heads:
            # wk shape is (n_kv_heads*head_dim, dim); check n_kv_heads
            if (kv[0] // self.head_dim) != self.n_kv_heads:
                return False, f"checkpoint n_kv_heads mismatch (wk {kv})"
        out = shape("output.weight")
        if out is not None and out[0] != self.vocab_size:
            return False, f"checkpoint vocab={out[0]} != config vocab={self.vocab_size}"
        return True, "ok"

    def matches_state_dict_shapes(self, cc):
        """Compare against a config-dict sidecar (keys: dim, n_layers, n_heads,
        n_kv_heads, hidden_dim, vocab_size). Returns (ok, reason)."""
        def g(k):
            return cc.get(k)
        if g("dim") is not None and g("dim") != self.dim:
            return False, f"checkpoint d_model={g('dim')} != config dim={self.dim}"
        if g("vocab_size") is not None and g("vocab_size") != self.vocab_size:
            return False, f"checkpoint vocab={g('vocab_size')} != config vocab={self.vocab_size}"
        if g("n_kv_heads") is not None and g("n_kv_heads") != self.n_kv_heads:
            return False, f"checkpoint n_kv_heads={g('n_kv_heads')} != config {self.n_kv_heads}"
        if g("n_heads") is not None and g("n_heads") != self.n_heads:
            return False, f"checkpoint n_heads={g('n_heads')} != config {self.n_heads}"
        if g("hidden_dim") is not None and g("hidden_dim") != self.hidden_dim:
            return False, f"checkpoint ffn={g('hidden_dim')} != config {self.hidden_dim}"
        return True, "ok"
