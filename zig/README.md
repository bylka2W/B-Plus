# B+ Programming Language

Unified compiler for PLAN (state machines/runtime) and METAL (GPU compute). Parser accepts everything; domain separation at HIR lowering.

## Pipeline

Parser → HIR → THIR → BIR → Mem2Reg → SSA BIR → Optimizer → MIR → Machine IR → Regalloc → x64 → PE → EXE

## Quick Start

```
bpc run file.b+
```
Compiles and runs a B+ source file.

## Changelog

### PLAN Runtime v1 (current)

- **State machine syntax:** `state`, `entry`, `exit`, `on event -> target`, `always`, `machine`, `initial`, `fire`
- **Keywords:** `kw_state`, `kw_entry`, `kw_exit`, `kw_on`, `kw_always`, `kw_machine`, `kw_fire`, `kw_parallel` (+ Russian aliases: `автомат`, `пуск`, `выйти`)
- **Exit states:** `exit {}` block — exit body executes before transition to next state (E2E: 022)
- **Guards:** `on event [condition] -> target` — `>=`, `<=`, `==`, `!=`, `>`, `<` with state variables (E2E: 023, 025)
- **Event dispatch:** stdin event loop — program reads events from stdin, dispatches transitions (E2E: 024)
- **Fire keyword:** `fire event` at top level — static event dispatch on startup (E2E: 021)
- **Runtime:** `src/runtime/state_machine.zig` — StateMachine struct, Transition table, bpc_fire() export
- **BIR representation:** SmTransition, SmState (`exit_fn: ?FunctionId`), StateMachine in module.zig
- **Tests:** 6 test suites pass (test, test-backend, test-thir, test-thir-to-bir, test-bir-mir, test-mir-machine)

### Previous

- Full SSA pipeline (BIR → MIR → Machine IR → Regalloc → x64)
- THIR layer with 41/41 tests
- x64 ABI (float args/returns, inline stack probe)
- GPU compute pipeline (HLSL, DXIL)
