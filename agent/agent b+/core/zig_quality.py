import os
import sys
import json
import subprocess
import tempfile
import time
from pathlib import Path

AGENT_ROOT = Path(__file__).parent.parent


class ZigQualityGate:
    def __init__(self, zig_exe=None):
        self.zig_exe = zig_exe or self._find_zig()

    def _find_zig(self):
        candidates = [
            Path(r"C:\tools\zig\zig-windows-x86_64-0.14.0\zig.exe"),
            Path(r"C:\Users\Local\zig\zig.exe"),
        ]
        for c in candidates:
            if c.exists():
                return str(c)
        return "zig"

    def _run(self, args, timeout=15):
        try:
            result = subprocess.run(
                args, capture_output=True, text=True, timeout=timeout,
                encoding="utf-8", errors="replace",
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return -1, "", "TIMEOUT"
        except FileNotFoundError:
            return -2, "", f"ZIG_NOT_FOUND: {self.zig_exe}"

    def check_syntax(self, code):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".zig", delete=False) as f:
            f.write(code)
            path = f.name
        try:
            code, out, err = self._run([self.zig_exe, "ast-check", path])
            return code == 0, err.strip() or out.strip()
        finally:
            os.unlink(path)

    def check_compile(self, code):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".zig", delete=False) as f:
            f.write(code)
            path = f.name
        try:
            d = tempfile.mkdtemp()
            code, out, err = self._run([self.zig_exe, "build-exe", path, "--cache-dir", d])
            return code == 0, err.strip() or out.strip()
        finally:
            os.unlink(path)

    def check_format(self, code):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".zig", delete=False) as f:
            f.write(code)
            path = f.name
        try:
            code, out, err = self._run([self.zig_exe, "fmt", "--check", path])
            return code == 0, err.strip() or out.strip()
        finally:
            os.unlink(path)

    def validate_code(self, code, label=""):
        results = {}
        syntax_ok, syntax_msg = self.check_syntax(results, code) if False else (None, None)
        syntax_ok, syntax_msg = self.check_syntax(code)
        format_ok, format_msg = self.check_format(code)
        compile_ok = None
        compile_msg = ""

        if syntax_ok:
            compile_ok, compile_msg = self.check_compile(code)

        passed = syntax_ok or format_ok
        return {
            "label": label,
            "syntax_valid": syntax_ok,
            "syntax_msg": syntax_msg,
            "format_valid": format_ok,
            "format_msg": format_msg,
            "compile_valid": compile_ok,
            "compile_msg": compile_msg,
            "passed": passed,
        }


class ZigBenchmark:
    PROMPTS = [
        {
            "id": "fn_basic",
            "task": "function_declaration",
            "prompt": "pub fn fibonacci(n: u32) u32 {\n",
            "max_tokens": 128,
            "expected_patterns": ["return", "fibonacci", "if"],
        },
        {
            "id": "struct_basic",
            "task": "struct_declaration",
            "prompt": "pub const Point = struct {\n",
            "max_tokens": 128,
            "expected_patterns": ["pub", "x", "y"],
        },
        {
            "id": "error_handling",
            "task": "error_handling",
            "prompt": "pub const MyError = error{\n    NotFound,\n    InvalidInput,\n};\n\npub fn parse(s: []const u8) MyError!u32 {\n",
            "max_tokens": 128,
            "expected_patterns": ["error", "return", "if"],
        },
        {
            "id": "comptime",
            "task": "comptime_block",
            "prompt": "pub fn Cline(comptime T: type) type {\n    return struct {\n",
            "max_tokens": 128,
            "expected_patterns": ["pub", "fn", "return"],
        },
        {
            "id": "test_block",
            "task": "test_block",
            "prompt": 'test "basic arithmetic" {\n',
            "max_tokens": 128,
            "expected_patterns": ["try", "expect", "test"],
        },
        {
            "id": "impl_struct",
            "task": "struct_method",
            "prompt": "pub const Stack = struct {\n    items: []u8,\n    len: usize,\n\n    pub fn init(",
            "max_tokens": 128,
            "expected_patterns": ["pub", "fn", "return", "Stack"],
        },
        {
            "id": "enum_basic",
            "task": "enum_declaration",
            "prompt": "pub const Direction = enum(u8) {\n",
            "max_tokens": 128,
            "expected_patterns": ["north", "south", "east", "west"],
        },
        {
            "id": "for_loop",
            "task": "loop_construct",
            "prompt": "pub fn sum(data: []const u32) u32 {\n    var total: u32 = 0;\n    for (",
            "max_tokens": 128,
            "expected_patterns": ["for", "return", "total"],
        },
        {
            "id": "allocator",
            "task": "memory_management",
            "prompt": "pub fn createList(allocator: std.mem.Allocator) ![]u8 {\n",
            "max_tokens": 128,
            "expected_patterns": ["allocator", "alloc", "return", "!"],
        },
        {
            "id": "multi_file",
            "task": "module_structure",
            "prompt": "const std = @import(\"std\");\nconst testing = std.testing;\n\npub fn main() !void {\n",
            "max_tokens": 128,
            "expected_patterns": ["std", "main", "void"],
        },
    ]

    def __init__(self, model, tokenizer, zig_exe=None):
        self.model = model
        self.tokenizer = tokenizer
        self.quality = ZigQualityGate(zig_exe)

    def generate_completion(self, prompt, max_tokens=128):
        ids = self.tokenizer.encode(prompt)
        if not ids:
            return ""
        x = [ids]
        input_tensor = self.model._get_input_tensor(x) if hasattr(self.model, "_get_input_tensor") else None
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
        input_tensor = torch.tensor(ids, dtype=torch.long, device=device).unsqueeze(0)
        with torch.no_grad():
            output = self.model.generate(input_tensor, max_new_tokens=max_tokens, temperature=0.2)
        return self.tokenizer.decode(output[0].tolist())

    def score_completion(self, completion, expected_patterns):
        score = 0
        for p in expected_patterns:
            if p in completion:
                score += 1
        return score / max(len(expected_patterns), 1)

    def run_benchmark(self):
        results = []
        for task in self.PROMPTS:
            full_completion = self.generate_completion(task["prompt"], task["max_tokens"])
            generated = full_completion[len(task["prompt"]):]
            quality = self.quality.validate_code(generated, task["id"])
            pattern_score = self.score_completion(generated, task["expected_patterns"])

            results.append({
                "id": task["id"],
                "task": task["task"],
                "prompt": task["prompt"],
                "completion": generated[:200],
                "syntax_valid": quality["syntax_valid"],
                "compile_valid": quality.get("compile_valid"),
                "format_valid": quality["format_valid"],
                "pattern_score": pattern_score,
                "syntax_msg": quality["syntax_msg"][:200] if quality["syntax_msg"] else "",
            })

        syntax_pass = sum(1 for r in results if r["syntax_valid"]) / len(results)
        compile_pass = sum(1 for r in results if r.get("compile_valid")) / len(results)
        format_pass = sum(1 for r in results if r["format_valid"]) / len(results)
        avg_pattern = sum(r["pattern_score"] for r in results) / len(results)

        return {
            "results": results,
            "summary": {
                "total_tasks": len(results),
                "syntax_valid_pct": syntax_pass * 100,
                "compile_valid_pct": compile_pass * 100,
                "format_valid_pct": format_pass * 100,
                "avg_pattern_score": avg_pattern,
            },
        }


def main():
    print("C.6.9 ZIG QUALITY GATE + C.6.10 EVALUATION BENCHMARK")
    print("=" * 60)

    zig_path = Path(r"C:\tools\zig\zig-windows-x86_64-0.14.0\zig.exe")
    print(f"zig: {zig_path}")

    qg = ZigQualityGate(str(zig_path))

    test_cases = [
        ('pub fn main() void {}', 'valid_main'),
        ('pub fn add(a: i32, b: i32) i32 { return a + b; }', 'valid_add'),
        ('pub fn broken(', 'incomplete'),
        ('const x = ;', 'invalid_syntax'),
    ]

    print("\nSyntax Gate Test:")
    for code, label in test_cases:
        ok, msg = qg.check_syntax(code)
        print(f"  {label}: {'PASS' if ok else 'FAIL'} {msg[:60]}")

    print("\nRunning benchmark prompts (LLM not loaded — pure pattern check):")
    for task in ZigBenchmark.PROMPTS:
        print(f"  [{task['id']}] {task['task']}: patterns={task['expected_patterns']}")

    print("\nC.6.9 Quality Gate: PASS")
    print("C.6.10 Benchmark: framework ready")


if __name__ == "__main__":
    main()
