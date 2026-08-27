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
        norm = x.float().pow(2).mean(-1, keepdim=True).add(self.eps).rsqrt()
        return (x.float() * norm).type_as(x) * self.weight


def precompute_freqs_cis(dim, max_seq_len, theta=10000.0):
    freqs = 1.0 / (theta ** (torch.arange(0, dim, 2).float() / dim))
    t = torch.arange(max_seq_len).float()
    freqs = torch.outer(t, freqs)
    return torch.polar(torch.ones_like(freqs), freqs)


def apply_rotary_emb(x, freqs_cis):
    x_complex = torch.view_as_complex(x.float().reshape(*x.shape[:-1], -1, 2))
    x_rotated = x_complex * freqs_cis.unsqueeze(0).unsqueeze(2)
    return torch.view_as_real(x_rotated).flatten(-2).type_as(x)


class SwiGLU(nn.Module):
    def __init__(self, dim, hidden_dim):
        super().__init__()
        self.w1 = nn.Linear(dim, hidden_dim, bias=False)
        self.w2 = nn.Linear(hidden_dim, dim, bias=False)
        self.w3 = nn.Linear(dim, hidden_dim, bias=False)

    def forward(self, x):
        return self.w2(F.silu(self.w1(x)) * self.w3(x))


class Attention(nn.Module):
    def __init__(self, dim, n_heads, max_seq_len=4096):
        super().__init__()
        self.n_heads = n_heads
        self.head_dim = dim // n_heads

        self.wq = nn.Linear(dim, n_heads * self.head_dim, bias=False)
        self.wk = nn.Linear(dim, n_heads * self.head_dim, bias=False)
        self.wv = nn.Linear(dim, n_heads * self.head_dim, bias=False)
        self.wo = nn.Linear(n_heads * self.head_dim, dim, bias=False)

        self.max_seq_len = max_seq_len
        self.register_buffer(
            "freqs_cis",
            precompute_freqs_cis(self.head_dim, max_seq_len),
            persistent=False,
        )

    def forward(self, x, mask=None):
        B, T, _ = x.shape
        q = self.wq(x).view(B, T, self.n_heads, self.head_dim).transpose(1, 2)
        k = self.wk(x).view(B, T, self.n_heads, self.head_dim).transpose(1, 2)
        v = self.wv(x).view(B, T, self.n_heads, self.head_dim).transpose(1, 2)

        freqs_cis = self.freqs_cis[:T].unsqueeze(0).unsqueeze(0)
        q = apply_rotary_emb(q, freqs_cis)
        k = apply_rotary_emb(k, freqs_cis)

        att = (q @ k.transpose(-2, -1)) / math.sqrt(self.head_dim)
        if mask is not None:
            att = att.masked_fill(mask[:, :, :T, :T] == 0, float("-inf"))
        att = F.softmax(att, dim=-1)
        out = (att @ v).transpose(1, 2).contiguous().view(B, T, -1)
        return self.wo(out)


class TransformerBlock(nn.Module):
    def __init__(self, dim, n_heads, hidden_dim, max_seq_len=4096):
        super().__init__()
        self.attention_norm = RMSNorm(dim)
        self.attention = Attention(dim, n_heads, max_seq_len)
        self.ffn_norm = RMSNorm(dim)
        self.ffn = SwiGLU(dim, hidden_dim)

    def forward(self, x, mask=None):
        x = x + self.attention(self.attention_norm(x), mask)
        x = x + self.ffn(self.ffn_norm(x))
        return x


class Transformer(nn.Module):
    def __init__(self, vocab_size=24000, dim=1024, n_layers=24, n_heads=16,
                 max_seq_len=4096, hidden_dim=2560):
        super().__init__()
        self.dim = dim
        self.n_layers = n_layers
        self.max_seq_len = max_seq_len
        self.tok_emb = nn.Embedding(vocab_size, dim)
        self.layers = nn.ModuleList([
            TransformerBlock(dim, n_heads, hidden_dim, max_seq_len)
            for _ in range(n_layers)
        ])
        self.norm = RMSNorm(dim)
        self.output = nn.Linear(dim, vocab_size, bias=False)
        self._init_weights()

    def _init_weights(self):
        for p in self.parameters():
            if p.dim() > 1:
                nn.init.xavier_uniform_(p)

    def forward(self, idx, targets=None):
        B, T = idx.shape
        x = self.tok_emb(idx)
        mask = torch.tril(torch.ones(self.max_seq_len, self.max_seq_len, device=x.device))
        mask = mask.unsqueeze(0).unsqueeze(0)
        for layer in self.layers:
            x = layer(x, mask)
        x = self.norm(x)
        logits = self.output(x)
        loss = None
        if targets is not None:
            loss = F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
        return logits, loss

    @torch.no_grad()
    def generate(self, idx, max_new_tokens=128, temperature=0.8, top_k=40):
        for _ in range(max_new_tokens):
            idx_cond = idx[:, -self.max_seq_len:]
            logits, _ = self(idx_cond)
            logits = logits[:, -1, :] / temperature
            if top_k > 0:
                v, _ = torch.topk(logits, min(top_k, logits.size(-1)))
                logits[logits < v[:, [-1]]] = float("-inf")
            probs = F.softmax(logits, dim=-1)
            idx_next = torch.multinomial(probs, num_samples=1)
            idx = torch.cat([idx, idx_next], dim=1)
        return idx

    def count_parameters(self):
        return sum(p.numel() for p in self.parameters())

    def get_config(self):
        return {
            "vocab_size": self.tok_emb.num_embeddings,
            "dim": self.dim,
            "n_layers": self.n_layers,
            "n_heads": self.layers[0].attention.n_heads,
            "max_seq_len": self.max_seq_len,
            "hidden_dim": self.layers[0].ffn.w1.out_features,
            "parameters": self.count_parameters(),
        }


def build_model(dim=1280, n_layers=24, n_heads=20, hidden_dim=3456, vocab_size=24000):
    return Transformer(
        vocab_size=vocab_size, dim=dim, n_layers=n_layers,
        n_heads=n_heads, max_seq_len=4096, hidden_dim=hidden_dim,
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
