# B+ Compiler Roadmap — Technical Fellow Level

## Current State

```
Source → Lexer → Green Tree → Red Tree → AST → Resolver → Type Engine → HIR → BIR (SSA) → MIR → x64 → PE
```

**Done:** Frontend, BIR with SSA, MIR passes, x64 backend, PE writer, verifier (7 modules), optimizer pipeline.

---

## Phase 1. Freeze Frontend

```
Lexer → Green Tree → Red Tree → AST → Resolver → Type Engine → HIR
```

After this, language changes happen below HIR only.

## Phase 2. Real HIR

```
HIR Module → HIR Item → HIR Body → HIR BasicBlock → HIR Expr → HIR Pattern → HIR Type → HIR Lifetime
```

## Phase 3. THIR (not exists yet)

```
HIR → THIR
```

THIR handles: coercion, overload resolution, implicit deref, auto borrow, pattern lowering, exhaustive match.

## Phase 4. Real MIR (Rust-style)

```
THIR → MIR Builder → Basic Blocks → Places → Operands → Statements → Terminators
```

## Phase 5. BIR (SSA)

```
MIR → SSA Builder → Phi → CFG → BIR → Optimizations
```

## Phase 6. Analysis Framework

- Alias Analysis
- Escape Analysis
- Loop Analysis
- Dominators / Post Dominators
- Control Dependence
- Memory Dependence
- Data Flow
- Constant Propagation
- Range Analysis
- Scalar Evolution
- Value Numbering
- Region Analysis
- Profile Analysis
- Inline Cost
- Lifetime Analysis
- Effect Analysis
- Borrow Analysis
- Object Lifetime

## Phase 7. Pass Manager (LLVM-style)

```
Pipeline → Analysis Manager → Pass Manager → Preserved Analyses → Invalidation → Scheduling → Dependency Graph
```

## Phase 8. Real Backend

```
BIR → Instruction Selection → Target DAG → Machine IR → Register Allocation → Stack Coloring → Frame Layout → Scheduling → Peephole → Machine Verification → Emission
```

## Phase 9. GPU Backend

```
BIR → GPU MIR → DXIL / SPIR-V / MSL / WGSL
```

## Phase 10. Driver

```
Driver → Job Graph → Compilation Database → Dependency Scanner → Cache → Incremental → LSP → IDE → Diagnostics → Code Completion
```

## Phase 11. Runtime

```
PLAN Runtime | METAL Runtime | GC | Allocator | Scheduler | Thread Pool | Reflection | Metadata
```

## Phase 12. Incremental Compilation

```
File Graph → Module Graph → Dependency Graph → Fingerprint → Incremental HIR → Incremental THIR → Incremental MIR → Incremental BIR
```

## Phase 13. Multithreading

All stages become independent. Each stage works in parallel across modules.

## Phase 14. LTO

```
Module → ThinLTO → Whole Program Analysis → Cross Module Inline → Global DCE → Final Binary
```

## Phase 15. PGO

```
Instrumentation → Profile → Hot Blocks → Reordering → Inlining → Branch Prediction
```

## Phase 16. Full Modularity

```
frontend/ middle/ backend/ runtime/ driver/ lsp/ gpu/ tools/ tests/ docs/ stdlib/
```

---

## Full Pipeline (Target Architecture)

```
Source → Lexer → Green Tree → Red Tree → AST → Resolver → Type Engine → HIR → THIR → MIR → SSA Builder → BIR → Analysis Framework → Optimization Pipeline → Instruction Selection → Machine IR → Register Allocation → Frame Layout → Instruction Scheduling → Code Emission → PE / ELF / Mach-O
```
