import sys
import json
from pathlib import Path

def audit_gpu():
    results = {}

    try:
        import torch
        results["torch_version"] = torch.__version__
        results["cuda_available"] = torch.cuda.is_available()
        results["cuda_version"] = torch.version.cuda or "N/A"
        results["cudnn_version"] = str(torch.backends.cudnn.version()) if torch.backends.cudnn.is_available() else "N/A"
        results["cuda_device_count"] = torch.cuda.device_count()
        if torch.cuda.is_available() and torch.cuda.device_count() > 0:
            results["cuda_device_name"] = torch.cuda.get_device_name(0)
            total_mem = torch.cuda.get_device_properties(0).total_mem
            results["cuda_vram_gb"] = round(total_mem / (1024**3), 1)
            results["cuda_compute_cap"] = f"{torch.cuda.get_device_capability(0)[0]}.{torch.cuda.get_device_capability(0)[1]}"
            results["cuda_max_threads"] = torch.cuda.get_device_properties(0).max_threads_per_block
            results["cuda_multiprocessors"] = torch.cuda.get_device_properties(0).multi_processor_count
        bf16 = torch.cuda.is_bf16_supported() if torch.cuda.is_available() else False
        results["bf16_supported"] = bf16
        fp16 = torch.cuda.is_available()
        results["fp16_supported"] = fp16
        results["device"] = "cuda" if torch.cuda.is_available() else "cpu"
    except ImportError as e:
        results["error"] = str(e)

    try:
        import subprocess
        r = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total,driver_version,compute_cap", "--format=csv,noheader"],
                          capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            results["nvidia_smi"] = r.stdout.strip()
    except Exception:
        pass

    return results


def estimate_500m_configs():
    configs = []
    for dim in [1024, 1152, 1280]:
        for n_layers in [24, 28, 30, 32]:
            for n_heads in [16, 20]:
                for hidden_dim_ratio in [2.5, 2.75, 3.0, 3.5]:
                    hidden_dim = int(dim * hidden_dim_ratio)
                    vocab_size = 16000
                    tok_emb = vocab_size * dim
                    out_emb = dim * vocab_size
                    layer_params = 0
                    layer_params += 4 * dim * dim
                    layer_params += 4 * dim * hidden_dim
                    layer_params += 2 * hidden_dim * dim
                    layer_params += 6 * dim
                    total = tok_emb + out_emb + n_layers * layer_params
                    configs.append({
                        "dim": dim, "n_layers": n_layers, "n_heads": n_heads,
                        "n_kv_heads": n_heads, "hidden_dim": hidden_dim,
                        "vocab_size": vocab_size, "params": total,
                        "params_m": round(total / 1e6, 1),
                    })

    configs.sort(key=lambda c: abs(c["params"] - 500e6))
    return configs[:10]


def main():
    print("C.6.1 GPU/CUDA AUDIT")
    print("=" * 60)
    gpu = audit_gpu()
    for k, v in gpu.items():
        print(f"  {k}: {v}")

    print(f"\nC.6.2 500M ARCHITECTURE CANDIDATES")
    print("=" * 60)
    candidates = estimate_500m_configs()
    for i, c in enumerate(candidates):
        print(f"  [{i+1}] {c['params_m']}M — dim={c['dim']}, layers={c['n_layers']}, "
              f"heads={c['n_heads']}, hidden={c['hidden_dim']}, vocab={c['vocab_size']}")

    best = candidates[0]
        print(f"  RECOMMENDED: dim={best['dim']}, layers={best['n_layers']}, "
              f"heads={best['n_heads']}, hidden={best['hidden_dim']}, "
              f"vocab={best['vocab_size']} -> {best['params_m']}M")

    report = {"gpu": gpu, "architecture_candidates": candidates, "recommended": best}
    report_path = Path(__file__).parent / "corpus" / "gpu_audit.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\nReport saved: {report_path}")

    sys.exit(0)


if __name__ == "__main__":
    main()
