import math
import torch
import torch.nn as nn
import torch.nn.functional as F


class RMSNorm(nn.Module):
    def __init__(self, dim, eps=1e-6):
        super().__init__()
        self.eps = eps
        self.weight = nn.Parameter(torch.ones(dim))

    def forward(self, x):
        # Fused RMSNorm (single kernel via torch's native implementation).
        return F.rms_norm(x.float(), (x.shape[-1],), self.weight.float(), eps=self.eps).type_as(x)


def precompute_freqs_cis(dim, max_seq_len, theta=10000.0):
    # Returns (cos, sin), each (max_seq_len, dim//2) -- real-valued, no complex
    # tensors (complex ops break torch.compile/Inductor fusion on this build).
    half = dim // 2
    inv_freq = 1.0 / (theta ** (torch.arange(0, half).float() / half))
    t = torch.arange(max_seq_len).float()
    freqs = torch.outer(t, inv_freq)
    return torch.cos(freqs), torch.sin(freqs)


def apply_rotary_emb(x, cos, sin):
    # x: (B, n_heads, T, head_dim); cos/sin: (T, head_dim//2)
    D = x.shape[-1]
    x1 = x[..., :D // 2]
    x2 = x[..., D // 2:]
    cos = cos.unsqueeze(0).unsqueeze(0)  # (1, 1, T, D//2)
    sin = sin.unsqueeze(0).unsqueeze(0)
    out1 = x1 * cos - x2 * sin
    out2 = x1 * sin + x2 * cos
    return torch.cat([out1, out2], dim=-1)


class SwiGLU(nn.Module):
    def __init__(self, dim, hidden_dim):
        super().__init__()
        # Fused gate: w1 and w3 combined into one matmul of 2*hidden, then split.
        self.w13 = nn.Linear(dim, 2 * hidden_dim, bias=False)
        self.w2 = nn.Linear(hidden_dim, dim, bias=False)

    def forward(self, x):
        a, b = self.w13(x).chunk(2, dim=-1)
        return self.w2(F.silu(a) * b)


class Attention(nn.Module):
    def __init__(self, dim, n_heads, n_kv_heads=None, max_seq_len=4096):
        super().__init__()
        self.n_heads = n_heads
        self.n_kv_heads = n_kv_heads or n_heads
        self.head_dim = dim // n_heads

        self.wq = nn.Linear(dim, n_heads * self.head_dim, bias=False)
        self.wk = nn.Linear(dim, self.n_kv_heads * self.head_dim, bias=False)
        self.wv = nn.Linear(dim, self.n_kv_heads * self.head_dim, bias=False)
        self.wo = nn.Linear(n_heads * self.head_dim, dim, bias=False)

        self.max_seq_len = max_seq_len
        cos, sin = precompute_freqs_cis(self.head_dim, max_seq_len)
        self.register_buffer("freqs_cos", cos, persistent=False)
        self.register_buffer("freqs_sin", sin, persistent=False)
        self.kv = None  # (K, V) cache for inference

    def reset_cache(self):
        self.kv = None

    def forward(self, x, start_pos=0, use_cache=False, cache=None, attn_mask=None):
        B, T, _ = x.shape
        q = self.wq(x).view(B, T, self.n_heads, self.head_dim).transpose(1, 2)
        k = self.wk(x).view(B, T, self.n_kv_heads, self.head_dim).transpose(1, 2)
        v = self.wv(x).view(B, T, self.n_kv_heads, self.head_dim).transpose(1, 2)

        cos = self.freqs_cos[start_pos:start_pos + T]
        sin = self.freqs_sin[start_pos:start_pos + T]
        q = apply_rotary_emb(q, cos, sin)
        k = apply_rotary_emb(k, cos, sin)

        if cache is not None:
            # Static decode path: read the FULL pre-allocated cache (fixed shape)
            # and gate with attn_mask. Native GQA via enable_gqa -> the 4 KV heads
            # are reused by the 24 Q heads WITHOUT materializing an expanded copy.
            # buffer layout: (n_kv_heads, cache_len, head_dim); write at dim 1.
            k_buf, v_buf = cache
            k_buf[:, start_pos:start_pos + T, :] = k.squeeze(0)
            v_buf[:, start_pos:start_pos + T, :] = v.squeeze(0)
            k_full = k_buf.unsqueeze(0)
            v_full = v_buf.unsqueeze(0)
            if attn_mask is not None:
                out = F.scaled_dot_product_attention(q, k_full, v_full,
                                                     attn_mask=attn_mask, enable_gqa=True)
            else:
                out = F.scaled_dot_product_attention(q, k_full, v_full,
                                                     is_causal=True, enable_gqa=True)
            out = out.transpose(1, 2).contiguous().view(B, T, -1)
            return self.wo(out)

        if use_cache and self.kv is not None:
            kc, vc = self.kv
            k = torch.cat([kc, k], dim=2)
            v = torch.cat([vc, v], dim=2)
        if use_cache:
            # detach so the cache is not part of the autograd graph
            self.kv = (k.detach(), v.detach())

        # Native GQA: q has n_heads, k/v have n_kv_heads; SDPA groups them without
        # physically expanding K/V (no repeat_interleave, no extra memory traffic).
        out = F.scaled_dot_product_attention(q, k, v, is_causal=True, enable_gqa=True)
        out = out.transpose(1, 2).contiguous().view(B, T, -1)
        return self.wo(out)


class TransformerBlock(nn.Module):
    def __init__(self, dim, n_heads, hidden_dim, n_kv_heads=None, max_seq_len=4096):
        super().__init__()
        self.attention_norm = RMSNorm(dim)
        self.attention = Attention(dim, n_heads, n_kv_heads, max_seq_len)
        self.ffn_norm = RMSNorm(dim)
        self.ffn = SwiGLU(dim, hidden_dim)

    def forward(self, x, start_pos=0, use_cache=False, cache=None, attn_mask=None):
        x = x + self.attention(self.attention_norm(x), start_pos=start_pos, use_cache=use_cache, cache=cache, attn_mask=attn_mask)
        x = x + self.ffn(self.ffn_norm(x))
        return x


class Transformer(nn.Module):
    def __init__(self, vocab_size=24000, dim=1024, n_layers=24, n_heads=16,
                 n_kv_heads=None, max_seq_len=4096, hidden_dim=2560):
        super().__init__()
        self.dim = dim
        self.n_layers = n_layers
        self.n_heads = n_heads
        self.n_kv_heads = n_kv_heads or n_heads
        self.max_seq_len = max_seq_len
        self.head_dim = dim // n_heads
        self.tok_emb = nn.Embedding(vocab_size, dim)
        self.layers = nn.ModuleList([
            TransformerBlock(dim, n_heads, hidden_dim, n_kv_heads, max_seq_len)
            for _ in range(n_layers)
        ])
        self.norm = RMSNorm(dim)
        self.output = nn.Linear(dim, vocab_size, bias=False)
        self._init_weights()

    def _init_weights(self):
        for p in self.parameters():
            if p.dim() > 1:
                nn.init.xavier_uniform_(p)

    def reset_cache(self):
        for layer in self.layers:
            layer.attention.reset_cache()

    def allocate_cache(self, device, dtype=None, max_seq=None):
        """Pre-allocate a static KV cache for inference.

        Returns a list of (k_buf, v_buf) per layer, each of shape
        (n_kv_heads, cache_len, head_dim). Writing in place avoids the
        per-token torch.cat that naive cache concat would do.
        """
        if dtype is None:
            dtype = torch.bfloat16
        cache_len = max_seq if max_seq is not None else self.max_seq_len
        cache = []
        for _ in range(self.n_layers):
            k = torch.zeros(self.n_kv_heads, cache_len, self.head_dim,
                            device=device, dtype=dtype)
            v = torch.zeros(self.n_kv_heads, cache_len, self.head_dim,
                            device=device, dtype=dtype)
            cache.append((k, v))
        return cache

    def forward(self, idx, targets=None, start_pos=0, use_cache=False, cache=None, attn_mask=None):
        B, T = idx.shape
        x = self.tok_emb(idx)
        # Causal masking is handled inside Attention via scaled_dot_product_attention
        # (is_causal=True); no explicit (max_seq_len x max_seq_len) mask is materialized,
        # so the model keeps its 256k positional capacity without OOM on short chunks.
        if cache is not None:
            for i, layer in enumerate(self.layers):
                x = layer(x, start_pos=start_pos, use_cache=use_cache, cache=cache[i], attn_mask=attn_mask)
        else:
            for layer in self.layers:
                x = layer(x, start_pos=start_pos, use_cache=use_cache)
        x = self.norm(x)
        logits = self.output(x)
        loss = None
        if targets is not None:
            loss = F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
        return logits, loss

    @torch.no_grad()
    def generate(self, idx, max_new_tokens=128, temperature=0.8, top_k=40):
        self.reset_cache()
        # Prefill the whole prompt once (fills KV cache for positions 0..T-1).
        pos = idx.shape[1]
        logits, _ = self(idx, start_pos=0, use_cache=True)
        idx_next = self._sample(logits[:, -1, :], temperature, top_k)
        generated = [idx_next]
        for _ in range(max_new_tokens - 1):
            logits, _ = self(idx_next, start_pos=pos, use_cache=True)
            pos += 1
            idx_next = self._sample(logits[:, -1, :], temperature, top_k)
            generated.append(idx_next)
        return torch.cat([idx, torch.cat(generated, dim=1)], dim=1)

    def _sample(self, logits, temperature, top_k):
        logits = logits / max(temperature, 1e-6)
        if top_k > 0:
            v, _ = torch.topk(logits, min(top_k, logits.size(-1)))
            logits[logits < v[:, [-1]]] = float("-inf")
        probs = F.softmax(logits, dim=-1)
        return torch.multinomial(probs, num_samples=1)

    def count_parameters(self):
        return sum(p.numel() for p in self.parameters())

    def get_config(self):
        return {
            "vocab_size": self.tok_emb.num_embeddings,
            "dim": self.dim,
            "n_layers": self.n_layers,
            "n_heads": self.n_heads,
            "n_kv_heads": self.n_kv_heads,
            "max_seq_len": self.max_seq_len,
            "hidden_dim": self.layers[0].ffn.w2.in_features,
            "parameters": self.count_parameters(),
        }


def build_model(dim=1280, n_layers=24, n_heads=20, hidden_dim=3456, vocab_size=24000):
    return Transformer(
        vocab_size=vocab_size, dim=dim, n_layers=n_layers,
        n_heads=n_heads, max_seq_len=4096, hidden_dim=hidden_dim,
    )


def build_model_600m(vocab_size=32000, max_seq_len=256000, cfg=None):
    """~600M param B+ Zig agent model with GQA.

    All dimensions come from ModelConfig (the single source of truth) so the
    constructed model always matches the tokenizer vocab and any loaded
    checkpoint. GQA (KV heads = 1/6 of Q heads) slashes KV-cache size / memory
    traffic, enabling high decode tok/s on a 16GB RTX 5060 Ti with 256k RoPE
    capacity. Only Russian + Zig are in vocab_size.
    """
    from core.model_config import ModelConfig
    if cfg is None:
        cfg = ModelConfig(vocab_size=vocab_size, max_seq_len=max_seq_len)
    return Transformer(
        vocab_size=cfg.vocab_size, dim=cfg.dim, n_layers=cfg.n_layers,
        n_heads=cfg.n_heads, n_kv_heads=cfg.n_kv_heads,
        max_seq_len=cfg.max_seq_len, hidden_dim=cfg.hidden_dim,
    )


def main():
    print("B+ ZIG AGENT MODEL")
    print("=" * 60)
    model = build_model()
    config = model.get_config()
    for k, v in config.items():
        if k == "parameters":
            print(f"  {k}: {v:,} ({v / 1e6:.1f}M)")
        else:
            print(f"  {k}: {v}")

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"\ndevice: {device}")
    model = model.to(device)

    x = torch.randint(0, 24000, (1, 128), device=device)
    targets = torch.randint(0, 24000, (1, 128), device=device)
    logits, loss = model(x, targets=targets)
    print(f"forward: input={x.shape} output={logits.shape} loss={loss.item():.4f}")

    gen = model.generate(x[:, :10], max_new_tokens=20)
    print(f"generate: input={x[:, :10].shape} output={gen.shape}")

    mb = sum(p.nelement() * p.element_size() for p in model.parameters()) / 1e6
    print(f"model size: {mb:.1f} MB")
    print(f"device: {device}")


if __name__ == "__main__":
    main()
