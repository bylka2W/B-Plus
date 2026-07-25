# B+ Compiler Roadmap — CPU First, Distinguished Engineer Level

## Philosophy

CPU compiler first. GPU later. Distinguished Engineer is evaluated on:
- language correctness
- type system
- IR design
- optimizer
- ABI
- machine code generation
- debugging
- profiling
- stability

LLVM became powerful as CPU IR/Backend first, then expanded.
Rust did the same: LLVM backend → many platforms → GPU projects later.

---

## Current Pipeline

```
Source → Lexer → Green Tree → Red Tree → AST → Resolver → Type Engine → HIR → BIR (SSA) → MIR → x64 → PE
```

**Done:** Frontend, BIR with SSA, MIR passes, x64 backend, PE writer, verifier (7 modules), optimizer pipeline.

---

## Phase 1 — Frontend Freeze ✅

```
Lexer → Parser → AST → Diagnostics → Symbol → Resolver
```

Almost done. Language changes happen below HIR only from now on.

## Phase 2 — Unified HIR

Problem: two HIR modules exist (`frontend/hir/`, `middle/hir/`).

Target:
```
HIR/
  nodes/
  types/
  lowering/
  ids/
```

AST never goes beyond this point.

## Phase 3 — THIR (Typed HIR)

```
HIR → THIR → BIR
```

THIR handles:
- all types resolved
- calls resolved
- generics expanded
- casts inserted
- overload selected
- coercion
- implicit deref
- pattern lowering
- exhaustive match

After THIR, the language is fully understood.

## Phase 4 — BIR to LLVM Level

Already strong:
✅ SSA, ✅ mem2reg, ✅ SCCP, ✅ GVN, ✅ DCE, ✅ CFG simplify, ✅ verifier

Add:
```
BIR/analysis/
  alias analysis
  escape analysis
  range analysis
  value numbering

BIR/optimizer/
  LICM
  loop rotate
  loop unroll
  inlining
  vectorization
```

## Phase 5 — Production MIR (Rust-style)

This is the main gap now.

```
MIR/
  Function
  Block
  Instruction
  Virtual Registers
  Physical Registers
  Frame Objects
  Calling Convention
```

Pipeline:
```
BIR → SSA Builder → Phi → CFG → MIR → Optimizations
```

Example:
```
BIR:  add i64
MIR:  vreg1 = ADD vreg2, vreg3
x64:  mov rax, rcx / add rax, rdx
```

## Phase 6 — CPU Backend

### x64
```
Instruction Selection → Register Allocation → Stack Frame
→ Prolog/Epilog → Calling Convention → Encoding → Relocations
```

### ARM64 (later)
```
Same pipeline, different target
```

### ABI Support
```
Windows: Win64 ABI, PE, COFF, DLL exports
Linux:   System V ABI, ELF
```

## Phase 7 — Runtime

```
runtime/
  memory/
  allocator/
  thread/
  sync/
  exception/
  ffi/
  startup/
```

## Phase 8 — Debugger Support

```
DWARF / PDB / source maps / stack traces

b+ code → debugger → breakpoint
```

## Phase 9 — Toolchain

```
bpc build    — compile
bpc run      — compile + execute
bpc test     — run tests
bpc fmt      — format
bpc check    — type check only
bpc doc      — generate docs
bpc lsp      — language server
bpc profile  — profiling
```

---

## After CPU is Stable — GPU

```
METAL → GPU IR → DXIL / SPIR-V / MSL / WGSL
```

METAL becomes: CPU target + GPU target + SIMD target — one computation model.

---

## After GPU — Advanced

- Incremental Compilation
- Multithreading (parallel stages)
- LTO (ThinLTO)
- PGO (Profile-Guided Optimization)
- Pass Manager (LLVM-style with Analysis Manager)

---

## Full Target Pipeline

```
Source → Lexer → Green Tree → Red Tree → AST → Resolver → Type Engine
  → HIR → THIR → MIR → SSA Builder → BIR
  → Analysis Framework → Optimization Pipeline
  → Instruction Selection → Machine IR → Register Allocation
  → Frame Layout → Instruction Scheduling → Code Emission
  → PE / ELF / Mach-O
```

---

## Priority Order

1. ✅ Frontend Freeze
2. Unified HIR
3. THIR
4. BIR to LLVM level
5. Production MIR
6. x64 backend (ABI level)
7. ARM64 backend
8. Runtime
9. Debugger support
10. Toolchain
11. GPU (METAL)
12. Incremental
13. Multithreading
14. LTO
15. PGO
