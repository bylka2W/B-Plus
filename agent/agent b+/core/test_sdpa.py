import torch, time
torch.cuda.init()
dev = "cuda:0"
print("torch", torch.__version__, "amp flash avail:", torch.cuda.is_available())
B, T = 2, 1024

def try_cfg(nh, nkv, hd, gqa, label):
    q = torch.randn(B, nh, T, hd, device=dev, dtype=torch.bfloat16, requires_grad=True)
    k = torch.randn(B, nkv, T, hd, device=dev, dtype=torch.bfloat16, requires_grad=True)
    v = torch.randn(B, nkv, T, hd, device=dev, dtype=torch.bfloat16, requires_grad=True)
    for name, cfg in [("flash", (True,False,False)), ("mem_eff", (False,True,False)), ("math", (False,False,True))]:
        try:
            with torch.backends.cuda.sdp_kernel(enable_flash=cfg[0], enable_mem_efficient=cfg[1], enable_math=cfg[2]):
                t0=time.monotonic()
                out = torch.nn.functional.scaled_dot_product_attention(q,k,v,is_causal=True, enable_gqa=gqa)
                loss = out.sum()
                loss.backward()
                dt=time.monotonic()-t0
            print(f"  [{label}] {name:8s} OK  fwd+bwd={dt*1000:.0f}ms", flush=True)
        except Exception as e:
            print(f"  [{label}] {name:8s} FAIL {type(e).__name__}: {str(e)[:60]}", flush=True)

print("CURRENT (nh=24,nkv=4,hd=60):")
try_cfg(24,4,60,True,"gqa")
try_cfg(24,4,60,False,"expand")
print("PROPOSED (nh=20,nkv=4,hd=72, %8):")
try_cfg(20,4,72,True,"gqa")
try_cfg(20,4,72,False,"expand")
