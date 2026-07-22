import subprocess, tempfile, os, time, sys

BPC = r"C:\B-Plus\zig\bpc.exe"

for i in range(5):
    code = f"state Main {{ entry {{ print({i}) }} }}"
    with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
        f.write(code)
        tmp = f.name
    t0 = time.time()
    try:
        r = subprocess.run(
            [BPC, "run", tmp],
            capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
            creationflags=0x08000000
        )
        dt = time.time() - t0
        print(f"#{i} exit={r.returncode} time={dt:.1f}s", flush=True)
    except subprocess.TimeoutExpired:
        print(f"#{i} TIMEOUT", flush=True)
    finally:
        try: os.unlink(tmp)
        except: pass
        exe = tmp.rsplit('.', 1)[0] + '.exe'
        try: 
            if os.path.exists(exe): os.unlink(exe)
        except: pass
print("ALL DONE", flush=True)
