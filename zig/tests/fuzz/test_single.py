import subprocess, tempfile, os, time, sys

BPC = r"C:\B-Plus\zig\bpc.exe"
code = "state Main { entry { print(1) } }"

with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
    f.write(code)
    tmp = f.name

print(f"tmp={tmp}", flush=True)
t0 = time.time()
try:
    r = subprocess.run(
        [BPC, "run", tmp],
        capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
        creationflags=0x08000000
    )
    dt = time.time() - t0
    print(f"exit={r.returncode} time={dt:.1f}s", flush=True)
    print(f"stderr={r.stderr.decode()[:200]}", flush=True)
except subprocess.TimeoutExpired:
    print(f"TIMEOUT after {time.time()-t0:.1f}s", flush=True)
except Exception as e:
    print(f"EXCEPTION: {e}", flush=True)
finally:
    os.unlink(tmp)
    exe = tmp.rsplit('.', 1)[0] + '.exe'
    if os.path.exists(exe): os.unlink(exe)
    print("DONE", flush=True)
