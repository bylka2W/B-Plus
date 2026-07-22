import subprocess, tempfile, os, time, sys

BPC = r"C:\B-Plus\zig\bpc.exe"

code = 'import "nonexistent.b+"\nstate Main { entry { print(1) } }'
with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
    f.write(code)
    tmp = f.name

print("Starting import test...", flush=True)
t0 = time.time()
try:
    r = subprocess.run(
        [BPC, "run", tmp],
        capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
        creationflags=0x08000000
    )
    dt = time.time() - t0
    print(f"exit={r.returncode} time={dt:.1f}s", flush=True)
    print(f"stdout={r.stdout.decode()[:200]}", flush=True)
    print(f"stderr={r.stderr.decode()[:200]}", flush=True)
except subprocess.TimeoutExpired:
    print(f"TIMEOUT after {time.time()-t0:.1f}s", flush=True)
finally:
    try: os.unlink(tmp)
    except: pass
    exe = tmp.rsplit('.', 1)[0] + '.exe'
    try:
        if os.path.exists(exe): os.unlink(exe)
    except: pass
    print("DONE", flush=True)
