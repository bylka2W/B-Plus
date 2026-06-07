using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using BPlus.Core.Ast;
using BPlus.Runtime;

namespace BPlus.Targets.Generators;

public class X64Output
{
    public byte[] Code { get; set; } = Array.Empty<byte>();
    public int ImportDirRva { get; set; }
    public int IdatSize { get; set; }
}

public class X64CodeGen
{
    private readonly List<byte> _code = new();
    private readonly Dictionary<string, int> _labels = new();
    private readonly List<(int offset, int dispSize, string label)> _pendingFixups = new();
    private readonly Dictionary<string, int> _stringPool = new(); // string → index
    private readonly List<string> _stringList = new();            // index → string content

    private ProgramNode _program = new();
    private List<string> _stateNames = new();
    private List<ContextVarInfo> _ctxVars = new();
    private Dictionary<string, List<StateVarInfo>> _stateVars = new();
    private int _stackFrameSize;

    // Stack frame offsets (from RBP, negative downward)
    private int _offHStdIn;
    private int _offHStdOut;
    private int _offCharsRead;
    private int _offCharsWritten;
    private int _offCurState;
    private int _offCursor;
    private int _offRemaining;
    private int _offBuf;
    private int _offCtxVarStart;
    private int _offStateDataBase; // base of shared state data block (zero-copy)
    private int _offCoreType;      // 0=unknown, 0x40=P-core, 0x20=E-core (from CPUID leaf 0x1A)
    private int _offNumaHighestNode; // DWORD — highest NUMA node number
    private int _offNumaNodeMask;    // QWORD — processor mask for the selected NUMA node

    // State code bounds for L1i budget tracking
    private readonly Dictionary<int, (int start, int end)> _stateCodeBounds = new();

    private static readonly string[] ImportFns = { "GetStdHandle", "WriteFile", "ReadFile", "ExitProcess", "GetProcessHeap", "HeapAlloc", "HeapFree", "SetThreadAffinityMask", "GetCurrentThread", "GetNumaHighestNodeNumber", "GetNumaNodeProcessorMask" };
    private const int IdxGetStdHandle = 0;
    private const int IdxWriteFile = 1;
    private const int IdxReadFile = 2;
    private const int IdxExitProcess = 3;
    private const int IdxGetProcessHeap = 4;
    private const int IdxHeapAlloc = 5;
    private const int IdxHeapFree = 6;
    private const int IdxSetThreadAffinityMask = 7;
    private const int IdxGetCurrentThread = 8;
    private const int IdxGetNumaHighestNodeNumber = 9;
    private const int IdxGetNumaNodeProcessorMask = 10;
    private const int StdInputHandle = -10;
    private const int StdOutputHandle = -11;
    private const int BufSize = 256;
    private const int SectionRva = 0x1000;

    // ── Public API ──
    public X64Output Generate(ProgramNode program)
    {
        _program = program;
        _stateNames = program.States.Select(s => s.Name).ToList();
        _ctxVars = program.Context?.Variables
            .Select(v => new ContextVarInfo { Name = v.Name, Type = v.Type, DefaultValue = v.DefaultValue ?? "0" })
            .ToList() ?? new();

        ComputeStackLayout();
        EmitPrologueAndInit();
        EmitStateEnterFuncs();
        PadForCacheAssociativity();
        EmitEventLoop();
        EmitCacheBudgetChecks();
        EmbedStringPool();
        int importDirRva = EmitImportTable();
        ApplyFixups();

        return new X64Output
        {
            Code = _code.ToArray(),
            ImportDirRva = importDirRva,
            IdatSize = ComputeImportTableSize()
        };
    }

    // ── Stack frame ──
    private void ComputeStackLayout()
    {
        int off = -8;
        _offHStdIn   = off; off -= 8;
        _offHStdOut  = off; off -= 8;
        _offCharsRead   = off; off -= 8;  // 8 bytes to match QWORD loads
        _offCharsWritten = off; off -= 8; // 8 bytes to match QWORD loads
        _offCurState = off; off -= 8;
        _offCursor   = off; off -= 8;   // current read cursor in buffer
        _offRemaining = off; off -= 8;  // remaining bytes in buffer
        // Context variables (before buffer, below curState/remaining)
        _offCtxVarStart = off;
        foreach (var _ in _ctxVars)
            off -= 8;

        // Shared state data block for zero-copy transitions
        // Variables with the same name share the same offset across states
        // All @cache(L1) variables are in one compact block for hw prefetcher
        _offStateDataBase = off;
        _stateVars.Clear();
        var sharedVarOffsets = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        int l1BlockStart = off;
        int l1BlockEnd = off;

        // First pass: allocate unique variable names for @cache(L1) states
        // Pack by natural alignment + actual size to avoid cache line holes
        foreach (var state in _program.States.Where(s => s.CachePolicy == "L1"))
        {
            var svList = new List<StateVarInfo>();
            foreach (var v in state.Variables)
            {
                if (!sharedVarOffsets.ContainsKey(v.Name))
                {
                    int align = GetTypeAlign(v.Type);
                    int size = GetTypeSize(v.Type);
                    off = (off / align) * align - size; // align down, then allocate
                    sharedVarOffsets[v.Name] = off;
                }
                svList.Add(new StateVarInfo {
                    Name = v.Name, Type = v.Type, DefaultValue = v.DefaultValue ?? "0",
                    StackOffset = sharedVarOffsets[v.Name], Size = GetTypeSize(v.Type)
                });
            }
            _stateVars[state.Name] = svList;
        }
        l1BlockEnd = off;

        // Second pass: non-L1 state variables (cold, normal) — also shared by name
        foreach (var state in _program.States.Where(s => s.CachePolicy != "L1"))
        {
            var svList = new List<StateVarInfo>();
            foreach (var v in state.Variables)
            {
                if (!sharedVarOffsets.ContainsKey(v.Name))
                {
                    int align = GetTypeAlign(v.Type);
                    int size = GetTypeSize(v.Type);
                    off = (off / align) * align - size;
                    sharedVarOffsets[v.Name] = off;
                }
                svList.Add(new StateVarInfo {
                    Name = v.Name, Type = v.Type, DefaultValue = v.DefaultValue ?? "0",
                    StackOffset = sharedVarOffsets[v.Name], Size = GetTypeSize(v.Type)
                });
            }
            _stateVars[state.Name] = svList;
        }
        // Input buffer at the bottom
        _offCoreType = off; off -= 4;  // 4-byte slot for core type from CPUID leaf 0x1A
        _offNumaHighestNode = off; off -= 4; // DWORD — highest NUMA node
        _offNumaNodeMask = off; off -= 8;    // QWORD — processor mask for preferred NUMA node
        _offBuf = off - BufSize; off -= BufSize;
        _stackFrameSize = (-off + 0xF) & ~0xF;
    }

    // ── Prologue & init ──
    private void EmitPrologueAndInit()
    {
        // Prologue
        Emit(OpCode.PUSH_R64,  R(Reg.RBP));
        Emit(OpCode.MOV_R64_R64, R(Reg.RBP), R(Reg.RSP));
        Emit(OpCode.PUSH_R64,  R(Reg.RBX));
        Emit(OpCode.PUSH_R64,  R(Reg.R12));
        Emit(OpCode.PUSH_R64,  R(Reg.R13));
        Emit(OpCode.PUSH_R64,  R(Reg.R14));
        Emit(OpCode.PUSH_R64,  R(Reg.R15));
        Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32((uint)_stackFrameSize));

        // Init context variables
        int off = _offCtxVarStart;
        foreach (var v in _ctxVars)
        {
            long val = ParseNumber(v.DefaultValue);
            EmitLoadImm(Reg.RAX, val);
            Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, off), R(Reg.RAX));
            off -= 8;
        }

        // Init all state variables with default values
        foreach (var svList in _stateVars.Values)
        {
            foreach (var sv in svList)
            {
                long val = ParseNumber(sv.DefaultValue);
                EmitLoadImm(Reg.RAX, val);
                EmitStoreVarFromReg(sv.StackOffset, Reg.RAX, sv.Size);
            }
        }

        // Set current_state = 0
        Emit(OpCode.XOR_R64_R64, R(Reg.RAX), R(Reg.RAX));
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offCurState), R(Reg.RAX));

        // GetStdHandle(STD_INPUT_HANDLE)
        EmitWin32Call(IdxGetStdHandle, StdInputHandle);
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offHStdIn), R(Reg.RAX));

        // GetStdHandle(STD_OUTPUT_HANDLE)
        EmitWin32Call(IdxGetStdHandle, StdOutputHandle);
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offHStdOut), R(Reg.RAX));

        // P/E-core affinity — detect hybrid topology and pin thread
        EmitAffinityInit();

        // Emit entry main() body (first entry only)
        if (_program.Entries.Count > 0)
        {
            var entry = _program.Entries[0];
            if (entry.BodyLines.Count > 0)
            {
                var lines = entry.BodyLines
                    .Select(l => l.Trim().TrimStart('{').TrimEnd('}').Trim())
                    .Where(l => l.Length > 0);
                EmitAction(string.Join("; ", lines));
            }
            else if (!string.IsNullOrEmpty(entry.Body))
                EmitAction(entry.Body);
        }

        // Call initial state enter (only if states exist)
        if (_program.States.Count > 0)
        {
            EmitCallToLabel("en_0");
            EmitLongJmp("evloop");
        }
    }

    // ── State enter functions ──
    private void EmitStateEnterFuncs()
    {
        var sorted = _program.States
            .Select((s, i) => (State: s, OrigIdx: i))
            .OrderByDescending(x => x.State.HotWeight >= 0.8 ? 2
                                  : x.State.HotWeight <= 0.3 ? 0
                                  : 1)
            .ThenBy(x => x.OrigIdx)
            .ToList();

        foreach (var (state, origIdx) in sorted)
        {
            // Align hot states to 64-byte cache line boundary (prevents split)
            if ((state.HotWeight ?? 0) >= 0.8)
            {
                int align = state.CacheAlign ?? 64;
                if (align == 64) AlignTo64();
                else if (align >= 16) { while (_code.Count % align != 0) _code.Add(0x90); }
            }
            int startOff = _code.Count;
            _labels["en_" + origIdx] = _code.Count;
            foreach (var act in state.Actions.Where(a => a.Type == ActionType.Enter))
                EmitAction(act.Body, state.Name);

            // Lookahead prefetch: prefetch data for the 2-3 most likely next transitions
            var likelyTransitions = state.Transitions
                .OrderByDescending(t => t.HotWeight ?? 0.5)
                .Take(3)
                .ToList();
            foreach (var t in likelyTransitions)
            {
                int ti = FindStateIndex(t.Target);
                var targetState = _program.States[ti];
                int level = targetState.CachePolicy switch { "L2" => 2, "L3" => 3, _ => 1 };
                if (_stateVars.TryGetValue(t.Target, out var vars))
                {
                    foreach (var sv in vars)
                        EmitPrefetchData(sv.StackOffset, level);
                }
                // Prefetch target enter code at L1i level
                if (level <= 1)
                    EmitPrefetch("en_" + ti);
            }

            Emit(OpCode.RET);
            int endOff = _code.Count;
            _stateCodeBounds[origIdx] = (startOff, endOff);
        }
    }

    // ── Event loop ──
    private void EmitEventLoop()
    {
        _labels["evloop"] = _code.Count;

        // ReadFile(hStdIn, buf, BufSize, &charsRead, null)
        Emit(OpCode.MOV_R64_MEM,  R(Reg.RCX), Mem(Reg.RBP, _offHStdIn));
        Emit(OpCode.LEA_R64_MEM,  R(Reg.RDX), Mem(Reg.RBP, _offBuf));
        EmitMovRegImm32(Reg.R8, BufSize);
        Emit(OpCode.LEA_R64_MEM,  R(Reg.R9),  Mem(Reg.RBP, _offCharsRead));
        Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(40)); // shadow + 5th arg
        EmitXorReg(Reg.RAX);
        Emit(OpCode.MOV_MEM_R64,   Mem(Reg.RSP, 32), R(Reg.RAX)); // overlapped = NULL
        EmitIatCall(IdxReadFile);
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(40));

        // If ReadFile failed, exit
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");

        // Load charsRead as 32-bit (zero-extends to 64), check for EOF
        Emit(OpCode.MOV_R32_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCharsRead));
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");

        // Initialize cursor = 0, remaining = charsRead (RAX already zero-extended)
        Emit(OpCode.XOR_R64_R64, R(Reg.RCX), R(Reg.RCX));
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offCursor), R(Reg.RCX));
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offRemaining), R(Reg.RAX));

        // ── Re-dispatch entry: skip ReadFile, process remaining buffer ──
        AlignTo16();
        _labels["re_dispatch"] = _code.Count;

        // If remaining == 0, no more data in buffer → read more
        Emit(OpCode.MOV_R32_MEM, R(Reg.RAX), Mem(Reg.RBP, _offRemaining));
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "evloop");

        // ── "exit" check at cursor position ──
        int exIdx = AddPoolString("exit");
        EmitRipLea(Reg.RSI, exIdx);
        Emit(OpCode.LEA_R64_MEM, R(Reg.RDI), Mem(Reg.RBP, _offBuf));
        Emit(OpCode.MOV_R32_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCursor));
        Emit(OpCode.ADD_R64_R64, R(Reg.RDI), R(Reg.RAX));
        string exLp = "exl";
        string exCe = "exce";
        _labels[exLp] = _code.Count;
        Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RAX), Mem(Reg.RDI, 0));
        Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RBX), Mem(Reg.RSI, 0));
        Emit(OpCode.CMP_R64_R64, R(Reg.RAX), R(Reg.RBX));
        EmitShortJmp(OpCode.JNE_REL8, exCe);
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");
        EmitInc(Reg.RDI);
        EmitInc(Reg.RSI);
        EmitShortJmp(OpCode.JMP_REL8, exLp);
        _labels[exCe] = _code.Count;
        Emit(OpCode.TEST_R64_R64, R(Reg.RBX), R(Reg.RBX));
        EmitShortJmp(OpCode.JNE_REL8, "no_exit");
        // Skip trailing whitespace before checking terminator
        EmitShortJmp(OpCode.JMP_REL8, "ex_chk_term");
        _labels["ex_skip_ws"] = _code.Count;
        EmitInc(Reg.RDI);
        Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RAX), Mem(Reg.RDI, 0));
        _labels["ex_chk_term"] = _code.Count;
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x20));
        EmitCondLongJmp(OpCode.JE_REL32, "ex_skip_ws");
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x09));
        EmitCondLongJmp(OpCode.JE_REL32, "ex_skip_ws");
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0A));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0D));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");
        EmitShortJmp(OpCode.JMP_REL8, "no_exit");
        _labels["no_exit"] = _code.Count;

        // Load current_state into R12
        Emit(OpCode.MOV_R32_MEM, R(Reg.R12), Mem(Reg.RBP, _offCurState));

        // Switch: cmp R12, i → je handler_i
        for (int i = 0; i < _stateNames.Count; i++)
        {
            Emit(OpCode.CMP_R64_IMM32, R(Reg.R12), ImmU32((uint)i));
            EmitCondLongJmp(OpCode.JE_REL32, "dp_" + i);
        }
        // Fallback: no matching state → re-dispatch
        EmitLongJmp("re_dispatch");

        // ── State dispatch handlers ──
        for (int si = 0; si < _program.States.Count; si++)
        {
            var dpState = _program.States[si];
            _labels["dp_" + si] = _code.Count;
            // Non-temporal prefetch for cold state data — evict from L1
            if ((dpState.HotWeight ?? 0.5) <= 0.3)
                EmitPrefetchColdData(dpState);
            EmitStateDispatch(dpState, si);
            // No transition matched → advance past this line, re-dispatch
            EmitLongJmp("advance_cursor");
        }

        // Safety fallback
        EmitLongJmp("advance_cursor");

        // ── Advance cursor past current line (shared snippet) ──
        AlignTo16();
        _labels["advance_cursor"] = _code.Count;

        // RDI = buf_start + cursor (current line start)
        Emit(OpCode.LEA_R64_MEM, R(Reg.RDI), Mem(Reg.RBP, _offBuf));
        Emit(OpCode.MOV_R32_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCursor));
        Emit(OpCode.ADD_R64_R64, R(Reg.RDI), R(Reg.RAX));
        // RBX = old cursor (save for delta computation)
        Emit(OpCode.MOV_R64_R64, R(Reg.RBX), R(Reg.RAX));
        // RCX = remaining (scan limit)
        Emit(OpCode.MOV_R32_MEM, R(Reg.RCX), Mem(Reg.RBP, _offRemaining));

        // Scan for \n, \r, or \0
        string advScan = "adv_scan";
        string advCr = "adv_cr";
        string advFound = "adv_found";
        string advDone = "adv_done";
        _labels[advScan] = _code.Count;
        Emit(OpCode.TEST_R64_R64, R(Reg.RCX), R(Reg.RCX));
        EmitShortJmp(OpCode.JE_REL8, advDone);        // exhausted → done
        Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RAX), Mem(Reg.RDI, 0));
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitShortJmp(OpCode.JE_REL8, advFound);        // null → found
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0A));
        EmitShortJmp(OpCode.JE_REL8, advFound);        // \n → found
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0D));
        EmitShortJmp(OpCode.JE_REL8, advCr);           // \r → handle CRLF
        EmitInc(Reg.RDI);
        EmitDec(Reg.RCX);
        EmitShortJmp(OpCode.JMP_REL8, advScan);

        _labels[advCr] = _code.Count;
        EmitInc(Reg.RDI);
        EmitDec(Reg.RCX);
        EmitShortJmp(OpCode.JE_REL8, advDone);               // RCX hit 0
        Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RAX), Mem(Reg.RDI, 0));  // load next byte
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0A));
        EmitShortJmp(OpCode.JNE_REL8, advDone);              // not CRLF → done
        EmitInc(Reg.RDI);
        EmitDec(Reg.RCX);
        EmitShortJmp(OpCode.JMP_REL8, advDone);              // done (skip advFound INC)

        _labels[advFound] = _code.Count;
        EmitInc(Reg.RDI);
        EmitDec(Reg.RCX);

        _labels[advDone] = _code.Count;
        // RDI = absolute position after consumed line's terminator
        // Compute new_cursor = RDI - (RBP + _offBuf)
        Emit(OpCode.LEA_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, _offBuf));
        Emit(OpCode.SUB_R64_R64, R(Reg.RDI), R(Reg.RAX));
        // RAX = consumed = new_cursor - old_cursor
        Emit(OpCode.MOV_R64_R64, R(Reg.RAX), R(Reg.RDI));
        Emit(OpCode.SUB_R64_R64, R(Reg.RAX), R(Reg.RBX));
        // _offRemaining -= consumed
        Emit(OpCode.MOV_R32_MEM, R(Reg.RCX), Mem(Reg.RBP, _offRemaining));
        Emit(OpCode.SUB_R64_R64, R(Reg.RCX), R(Reg.RAX));
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offRemaining), R(Reg.RCX));
        // _offCursor = new_cursor
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offCursor), R(Reg.RDI));
        EmitLongJmp("re_dispatch");

        // ── Exit handler ──
        _labels["exit_process"] = _code.Count;
        EmitWin32Call(IdxExitProcess, 0);
        // In case ExitProcess somehow returns, retry
        EmitLongJmp("exit_process");
    }

    private void EmitStateDispatch(StateDefNode state, int si)
    {
        // Always/auto transitions (no event name)
        foreach (var t in state.Transitions)
        {
            if (string.IsNullOrEmpty(t.EventName) && !t.IsAlways)
                continue;
            if (t.IsAlways && string.IsNullOrEmpty(t.EventName))
            {
                if (string.IsNullOrEmpty(t.Guard))
                {
                    // Unconditional always — always fires, no event-driven dispatch needed
                    if (!string.IsNullOrEmpty(t.Body))
                        EmitAction(t.Body, state.Name);
                    ChangeToState(t.Target, si);
                    return;
                }
                // Guarded always — if guard fails, fall through to event-driven dispatch
                EmitGuardSkip(t.Guard, si, -1);
                if (!string.IsNullOrEmpty(t.Body))
                    EmitAction(t.Body, state.Name);
                ChangeToState(t.Target, si);
                _labels[$"sk_{si}_{-1}"] = _code.Count;
            }
        }

        // Group event-driven transitions by event name
        var eventGroups = state.Transitions
            .Where(t => !string.IsNullOrEmpty(t.EventName))
            .GroupBy(t => t.EventName)
            .ToList();

        int egIdx = 0;
        foreach (var group in eventGroups)
        {
            string eventName = group.Key;
            var transList = group.ToList();

            // Emit string comparison: buffer vs event name
            int strOff = AddPoolString(eventName);
            EmitRipLea(Reg.RSI, strOff);
            Emit(OpCode.LEA_R64_MEM, R(Reg.RDI), Mem(Reg.RBP, _offBuf));
            Emit(OpCode.MOV_R32_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCursor));
            Emit(OpCode.ADD_R64_R64, R(Reg.RDI), R(Reg.RAX));

            string loopLabel = $"eg_lp_{si}_{egIdx}";
            string checkEnd = $"eg_ce_{si}_{egIdx}";
            _labels[loopLabel] = _code.Count;
            Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RAX), Mem(Reg.RDI, 0));
            Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RBX), Mem(Reg.RSI, 0));
            Emit(OpCode.CMP_R64_R64, R(Reg.RAX), R(Reg.RBX));
            EmitShortJmp(OpCode.JNE_REL8, checkEnd);
            Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
            EmitShortJmp(OpCode.JE_REL8, $"eg_mt_{si}_{egIdx}");
            EmitInc(Reg.RDI);
            EmitInc(Reg.RSI);
            EmitShortJmp(OpCode.JMP_REL8, loopLabel);

            // Event end check: event byte != 0 → real mismatch → skip group
            _labels[checkEnd] = _code.Count;
            Emit(OpCode.TEST_R64_R64, R(Reg.RBX), R(Reg.RBX));
            EmitCondLongJmp(OpCode.JNE_REL32, $"eg_done_{si}_{egIdx}");
            // Skip trailing whitespace then check for terminators
            EmitShortJmp(OpCode.JMP_REL8, $"eg_skip_{si}_{egIdx}");
            _labels[$"eg_ws_{si}_{egIdx}"] = _code.Count;
            EmitInc(Reg.RDI);
            Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RAX), Mem(Reg.RDI, 0));
            _labels[$"eg_skip_{si}_{egIdx}"] = _code.Count;
            Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x20));
            EmitShortJmp(OpCode.JE_REL8, $"eg_ws_{si}_{egIdx}");
            Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x09));
            EmitShortJmp(OpCode.JE_REL8, $"eg_ws_{si}_{egIdx}");
            Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
            EmitShortJmp(OpCode.JE_REL8, $"eg_mt_{si}_{egIdx}");
            Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0A));
            EmitShortJmp(OpCode.JE_REL8, $"eg_mt_{si}_{egIdx}");
            Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0D));
            EmitShortJmp(OpCode.JE_REL8, $"eg_mt_{si}_{egIdx}");
            EmitLongJmp($"eg_done_{si}_{egIdx}");

            // Event matched — try each transition in priority order
            _labels[$"eg_mt_{si}_{egIdx}"] = _code.Count;

            // Split: specific guards first, then guardless, then != guards last
            var specificGuards = transList.Where(t => !string.IsNullOrEmpty(t.Guard) && !t.Guard.Contains("!=")).ToList();
            var neqGuards = transList.Where(t => t.Guard?.Contains("!=") ?? false).ToList();
            var guardlessList = transList.Where(t => string.IsNullOrEmpty(t.Guard)).ToList();

            // 1) Specific guarded transitions first (==, >=, <=, >, <)
            foreach (var t in specificGuards)
            {
                int origTi = state.Transitions.IndexOf(t);
                EmitGuardSkip(t.Guard!, si, origTi);
                EmitPrefetchForTransitionCacheAware(t);
                if (!string.IsNullOrEmpty(t.Body))
                    EmitAction(t.Body, state.Name);
                ChangeToState(t.Target, si);
                _labels[$"sk_{si}_{origTi}"] = _code.Count;
            }
            // 2) Guardless fallback
            foreach (var t in guardlessList)
            {
                EmitPrefetchForTransitionCacheAware(t);
                if (!string.IsNullOrEmpty(t.Body))
                    EmitAction(t.Body, state.Name);
                ChangeToState(t.Target, si);
            }
            // 3) != guards last (broadest)
            foreach (var t in neqGuards)
            {
                int origTi = state.Transitions.IndexOf(t);
                EmitGuardSkip(t.Guard!, si, origTi);
                EmitPrefetchForTransitionCacheAware(t);
                if (!string.IsNullOrEmpty(t.Body))
                    EmitAction(t.Body, state.Name);
                ChangeToState(t.Target, si);
                _labels[$"sk_{si}_{origTi}"] = _code.Count;
            }

            // Event group skip label — event name mismatch or all guards failed with no fallback
            _labels[$"eg_done_{si}_{egIdx}"] = _code.Count;
            egIdx++;
        }
    }

    // ── Guard handling ──
    private void EmitGuardSkip(string? guard, int si, int ti)
    {
        if (string.IsNullOrEmpty(guard)) return;

        string skipLabel = $"sk_{si}_{ti}"; // same skip target as transition mismatch
        string curStateName = _program.States[si].Name;

        var (lhs, op, rhs) = ParseGuard(guard);

        // Load lhs — check context, then state vars, then constant
        if (!TryLoadVarToReg(Reg.RAX, lhs, curStateName))
        {
            if (long.TryParse(lhs, out long lv))
                EmitLoadImm(Reg.RAX, lv);
            else
                EmitXorReg(Reg.RAX);
        }

        // Load rhs — check context, then state vars, then constant
        if (!TryLoadVarToReg(Reg.RBX, rhs, curStateName))
        {
            if (long.TryParse(rhs, out long rv))
                EmitLoadImm(Reg.RBX, rv);
            else
                Emit(OpCode.XOR_R64_R64, R(Reg.RBX), R(Reg.RBX));
        }

        Emit(OpCode.CMP_R64_R64, R(Reg.RAX), R(Reg.RBX));

        switch (op)
        {
            case ">" : EmitCondLongJmp(OpCode.JLE_REL32, skipLabel); break;
            case "<" : EmitCondLongJmp(OpCode.JGE_REL32, skipLabel); break;
            case ">=": EmitCondLongJmp(OpCode.JL_REL32,  skipLabel); break;
            case "<=": EmitCondLongJmp(OpCode.JG_REL32,  skipLabel); break;
            case "==": EmitCondLongJmp(OpCode.JNE_REL32, skipLabel); break;
            case "!=": EmitCondLongJmp(OpCode.JE_REL32,  skipLabel); break;
        }
    }

    // ── State change ──
    private void ChangeToState(string targetName, int currentStateIdx)
    {
        int ti = FindStateIndex(targetName);

        // Emit exit actions for current state
        var curState = _program.States[currentStateIdx];
        foreach (var act in curState.Actions.Where(a => a.Type == ActionType.Exit))
            EmitAction(act.Body, curState.Name);

        // current_state = ti
        EmitMovRegImm32(Reg.RAX, (uint)ti);
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offCurState), R(Reg.RAX));

        // Zero-copy transition: NO variable re-initialization.
        // Variables persist in the shared state data block.
        // The target state's enter function handles any needed setup.

        // call enter_{ti}
        EmitCallToLabel("en_" + ti);
        // advance cursor and re-dispatch remaining buffer content
        EmitLongJmp("advance_cursor");
    }

    // ── Action emission (supports semicolons) ──
    private void EmitAction(string? body, string currentStateName = "")
    {
        if (string.IsNullOrEmpty(body)) return;
        foreach (var stmt in body.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            EmitSingleAction(stmt, currentStateName);
    }

    private void EmitSingleAction(string body, string currentStateName)
    {
        if (string.IsNullOrEmpty(body)) return;

        // print("...")
        if (body.StartsWith("print(") && body.EndsWith(")"))
        {
            string content = body.Substring(6, body.Length - 7).Trim().Trim('"');
            if (string.IsNullOrEmpty(content)) return;
            int strOff = AddPoolString(content);

            Emit(OpCode.MOV_R64_MEM,    R(Reg.RCX), Mem(Reg.RBP, _offHStdOut));
            EmitRipLea(Reg.RDX, strOff);
            Emit(OpCode.MOV_R64_IMM64,  R(Reg.R8),  Imm(Encoding.UTF8.GetByteCount(content)));
            Emit(OpCode.LEA_R64_MEM,    R(Reg.R9),  Mem(Reg.RBP, _offCharsWritten));
            Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(40)); // shadow + 5th arg
            EmitXorReg(Reg.RAX);
            Emit(OpCode.MOV_MEM_R64,    Mem(Reg.RSP, 32), R(Reg.RAX)); // 5th arg at safe offset
            EmitIatCall(IdxWriteFile);
            Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(40));
            return;
        }

        // free(ptr)
        if (body.StartsWith("free(") && body.EndsWith(")"))
        {
            string ptrName = body.Substring(5, body.Length - 6).Trim();
            // GetProcessHeap() → RAX
            Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(40));
            EmitIatCall(IdxGetProcessHeap);
            Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(40));
            Emit(OpCode.MOV_R64_R64, R(Reg.RCX), R(Reg.RAX));
            // RDX = dwFlags = 0
            Emit(OpCode.XOR_R64_R64, R(Reg.RDX), R(Reg.RDX));
            // R8 = pointer value
            if (!TryLoadVarToReg(Reg.R8, ptrName, currentStateName))
                Emit(OpCode.XOR_R64_R64, R(Reg.R8), R(Reg.R8));
            // Call HeapFree
            Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(40));
            EmitIatCall(IdxHeapFree);
            Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(40));
            return;
        }

        // Compound assignment: var += expr
        if (body.Contains("+="))
        {
            int idx = body.IndexOf("+=");
            string varName = body.Substring(0, idx).Trim();
            string expr = body.Substring(idx + 2).Trim();
            int vo = GetVarOffset(currentStateName, varName);
            if (vo != int.MinValue)
            {
                int size = GetVarSize(currentStateName, varName);
                EmitLoadVarToReg(Reg.RAX, vo, size);
                EmitExprToRAXAdd(expr, currentStateName);
                EmitStoreVarFromReg(vo, Reg.RAX, size);
            }
            return;
        }

        // Compound assignment: var -= expr
        if (body.Contains("-="))
        {
            int idx = body.IndexOf("-=");
            string varName = body.Substring(0, idx).Trim();
            string expr = body.Substring(idx + 2).Trim();
            int vo = GetVarOffset(currentStateName, varName);
            if (vo != int.MinValue)
            {
                int size = GetVarSize(currentStateName, varName);
                EmitLoadVarToReg(Reg.RAX, vo, size);
                EmitExprToRAXSub(expr, currentStateName);
                EmitStoreVarFromReg(vo, Reg.RAX, size);
            }
            return;
        }

        // Assignment: var = expr
        int eq = body.IndexOf('=');
        if (eq > 0)
        {
            string varName = body.Substring(0, eq).Trim();
            string expr = body.Substring(eq + 1).Trim();
            int vo = GetVarOffset(currentStateName, varName);
            if (vo != int.MinValue)
            {
                EmitExprToRAX(expr, currentStateName);
                int size = GetVarSize(currentStateName, varName);
                EmitStoreVarFromReg(vo, Reg.RAX, size);
            }
            return;
        }
    }

    private int GetVarOffset(string stateName, string varName)
    {
        int ci = _ctxVars.FindIndex(v => v.Name == varName);
        if (ci >= 0) return _offCtxVarStart - ci * 8;
        if (!string.IsNullOrEmpty(stateName) && _stateVars.TryGetValue(stateName, out var svList))
        {
            var sv = svList.FirstOrDefault(v => v.Name == varName);
            if (sv != null) return sv.StackOffset;
        }
        return int.MinValue;
    }

    private bool TryLoadVarToReg(int reg, string name, string stateName)
    {
        int vo = GetVarOffset(stateName, name);
        if (vo != int.MinValue)
        {
            int size = GetVarSize(stateName, name);
            EmitLoadVarToReg(reg, vo, size);
            return true;
        }
        return false;
    }

    private int GetVarSize(string stateName, string name)
    {
        int ci = _ctxVars.FindIndex(v => v.Name == name);
        if (ci >= 0) return 8;
        if (!string.IsNullOrEmpty(stateName) && _stateVars.TryGetValue(stateName, out var svList))
        {
            var sv = svList.FirstOrDefault(v => v.Name == name);
            if (sv != null) return sv.Size;
        }
        return 8;
    }

    private void EmitExprToRAX(string expr, string stateName)
    {
        expr = expr.Trim();
        int plusIdx = expr.LastIndexOf('+');
        int minusIdx = expr.LastIndexOf('-');

        if (plusIdx > 0)
        {
            string lhs = expr.Substring(0, plusIdx).Trim();
            string rhs = expr.Substring(plusIdx + 1).Trim();
            EmitExprAtomToRAX(lhs, stateName);
            if (TryLoadVarToReg(Reg.RBX, rhs, stateName))
                Emit(OpCode.ADD_R64_R64, R(Reg.RAX), R(Reg.RBX));
            else if (long.TryParse(rhs, out long rv))
                Emit(OpCode.ADD_R64_IMM32, R(Reg.RAX), ImmU32((uint)rv));
            return;
        }

        if (minusIdx > 0)
        {
            string lhs = expr.Substring(0, minusIdx).Trim();
            string rhs = expr.Substring(minusIdx + 1).Trim();
            EmitExprAtomToRAX(lhs, stateName);
            if (TryLoadVarToReg(Reg.RBX, rhs, stateName))
                Emit(OpCode.SUB_R64_R64, R(Reg.RAX), R(Reg.RBX));
            else if (long.TryParse(rhs, out long rv))
                Emit(OpCode.SUB_R64_IMM32, R(Reg.RAX), ImmU32((uint)rv));
            return;
        }

        EmitExprAtomToRAX(expr, stateName);
    }

    private void EmitExprToRAXAdd(string expr, string stateName)
    {
        expr = expr.Trim();
        if (TryLoadVarToReg(Reg.RBX, expr, stateName))
            Emit(OpCode.ADD_R64_R64, R(Reg.RAX), R(Reg.RBX));
        else if (long.TryParse(expr, out long rv))
            Emit(OpCode.ADD_R64_IMM32, R(Reg.RAX), ImmU32((uint)rv));
    }

    private void EmitExprToRAXSub(string expr, string stateName)
    {
        expr = expr.Trim();
        if (TryLoadVarToReg(Reg.RBX, expr, stateName))
            Emit(OpCode.SUB_R64_R64, R(Reg.RAX), R(Reg.RBX));
        else if (long.TryParse(expr, out long rv))
            Emit(OpCode.SUB_R64_IMM32, R(Reg.RAX), ImmU32((uint)rv));
    }

    private void EmitExprAtomToRAX(string atom, string stateName)
    {
        atom = atom.Trim();

        // malloc(size) — returns pointer in RAX
        if (atom.StartsWith("malloc(") && atom.EndsWith(")"))
        {
            string sizeExpr = atom.Substring(7, atom.Length - 8).Trim();
            long szVal = ParseNumber(sizeExpr);
            // GetProcessHeap() → RAX
            ShadowCall(IdxGetProcessHeap);
            Emit(OpCode.MOV_R64_R64, R(Reg.RCX), R(Reg.RAX));
            // dwFlags = 0
            Emit(OpCode.XOR_R64_R64, R(Reg.RDX), R(Reg.RDX));
            // dwBytes = size
            Emit(OpCode.MOV_R64_IMM64, R(Reg.R8), Imm(szVal));
            // HeapAlloc
            ShadowCall(IdxHeapAlloc);
            return;
        }

        // *ptr — dereference pointer
        if (atom.StartsWith("*"))
        {
            string ptrName = atom.Substring(1).Trim();
            if (!TryLoadVarToReg(Reg.RAX, ptrName, stateName))
                Emit(OpCode.XOR_R64_R64, R(Reg.RAX), R(Reg.RAX));
            Emit(OpCode.MOV_R64_MEM, R(Reg.RAX), Mem(Reg.RAX, 0));
            return;
        }

        if (!TryLoadVarToReg(Reg.RAX, atom, stateName))
        {
            if (long.TryParse(atom, out long v))
                EmitLoadImm(Reg.RAX, v);
            else
                EmitXorReg(Reg.RAX);
        }
    }

    // ── Guard parser ──
    private (string lhs, string op, string rhs) ParseGuard(string g)
    {
        string[] ops = { ">=", "<=", "==", "!=", ">", "<" };
        foreach (var o in ops)
        {
            int idx = g.IndexOf(o, StringComparison.Ordinal);
            if (idx > 0)
                return (g.Substring(0, idx).Trim(), o, g.Substring(idx + o.Length).Trim());
        }
        return ("", "", "");
    }

    // ── String pool ──
    private int AddPoolString(string s)
    {
        if (_stringPool.TryGetValue(s, out int idx)) return idx;
        idx = _stringList.Count;
        _stringPool[s] = idx;
        _stringList.Add(s);
        return idx;
    }

    private void EmbedStringPool()
    {
        for (int i = 0; i < _stringList.Count; i++)
        {
            _labels["str_" + i] = _code.Count;
            byte[] b = Encoding.UTF8.GetBytes(_stringList[i]);
            _code.AddRange(b);
            _code.Add(0);
        }
    }

    // ── Import table ──
    private int EmitImportTable()
    {
        int baseOff = _code.Count;
        int nf = ImportFns.Length;
        int descSize = 2 * 20; // kernel32 + terminator

        int intOff = baseOff + descSize;
        int intSz = (nf + 1) * 8;
        int dllNameOff = intOff + intSz;
        byte[] dllName = Encoding.ASCII.GetBytes("kernel32.dll\0");

        int hintBase = dllNameOff + dllName.Length;
        var hintOffs = new List<int>();
        var hintDat = new List<byte[]>();
        int cur = hintBase;
        foreach (string fn in ImportFns)
        {
            hintOffs.Add(cur);
            byte[] d = Encoding.ASCII.GetBytes(fn + "\0");
            hintDat.Add(d);
            cur += 2 + d.Length;
        }
        int iatOff = cur;
        int iatSz = (nf + 1) * 8;

        // Descriptor: kernel32.dll  (all RVAs need SectionRva added)
        _code.AddRange(BitConverter.GetBytes((uint)(SectionRva + intOff)));   // OriginalFirstThunk
        _code.AddRange(BitConverter.GetBytes(0u));                            // TimeDateStamp
        _code.AddRange(BitConverter.GetBytes(0u));                            // ForwarderChain
        _code.AddRange(BitConverter.GetBytes((uint)(SectionRva + dllNameOff)));// Name
        _code.AddRange(BitConverter.GetBytes((uint)(SectionRva + iatOff)));   // FirstThunk
        // Terminator
        for (int i = 0; i < 20; i++) _code.Add(0);

        // INT array  (entries are RVAs)
        for (int i = 0; i < nf; i++)
            _code.AddRange(BitConverter.GetBytes((ulong)(uint)(SectionRva + hintOffs[i])));
        _code.AddRange(new byte[8]);

        // DLL name
        _code.AddRange(dllName);

        // Hint/name entries
        for (int i = 0; i < nf; i++)
        {
            _code.Add(0); _code.Add(0);
            _code.AddRange(hintDat[i]);
        }

        // IAT  (entries are RVAs; PE loader replaces with function addresses)
        for (int i = 0; i < nf; i++)
            _code.AddRange(BitConverter.GetBytes((ulong)(uint)(SectionRva + hintOffs[i])));
        _code.AddRange(new byte[8]);

        // Store IAT entry offsets for fixups
        for (int i = 0; i < nf; i++)
            _labels["iat_" + i] = iatOff + i * 8;

        return baseOff;
    }

    private int ComputeImportTableSize()
    {
        int nf = ImportFns.Length;
        int desc = 2 * 20;
        int intSz = (nf + 1) * 8;
        byte[] dllName = Encoding.ASCII.GetBytes("kernel32.dll\0");
        int hintSz = 0;
        foreach (string fn in ImportFns)
            hintSz += 2 + Encoding.ASCII.GetBytes(fn + "\0").Length;
        int iatSz = (nf + 1) * 8;
        return desc + intSz + dllName.Length + hintSz + iatSz;
    }

    private void ApplyFixups()
    {
        foreach (var (off, ds, lab) in _pendingFixups)
        {
            int target;
            if (lab.StartsWith("__abs_"))
                target = int.Parse(lab.Substring(6));
            else
                target = _labels.GetValueOrDefault(lab, -1);

            if (target < 0 || off < 0 || off + ds > _code.Count) continue;

            int disp = target - (off + ds);
            if (ds == 1)
            {
                if (disp >= sbyte.MinValue && disp <= sbyte.MaxValue)
                    _code[off] = (byte)(sbyte)disp;
            }
            else if (ds == 4)
            {
                byte[] b = BitConverter.GetBytes(disp);
                for (int i = 0; i < 4 && off + i < _code.Count; i++)
                    _code[off + i] = b[i];
            }
        }
    }

    // ── Emit helpers ──

    // Short (rel8) jump with label fixup
    private void EmitShortJmp(OpCode op, string label)
    {
        Emit(op, Imm(0));
        _pendingFixups.Add((_code.Count - 1, 1, label));
    }

    // Long (rel32) jump with label fixup (for distant targets like evloop)
    private void EmitLongJmp(string label)
    {
        Emit(OpCode.JMP_REL32, Imm(0));
        _pendingFixups.Add((_code.Count - 4, 4, label));
    }

    // Long (rel32) conditional jump with label fixup
    private void EmitCondLongJmp(OpCode op, string label)
    {
        Emit(op, Imm(0));
        _pendingFixups.Add((_code.Count - 4, 4, label));
    }

    // CALL rel32 with label fixup
    private void EmitCallToLabel(string label)
    {
        Emit(OpCode.CALL_REL32, Imm(0));
        _pendingFixups.Add((_code.Count - 4, 4, label));
    }

    // LEA r64, [rip+disp] — placeholder disp, resolved via label fixup
    private void EmitRipLea(int dstReg, int stringIdx)
    {
        Emit(OpCode.LEA_R64_MEM, R(dstReg), Mem(255, 0)); // placeholder disp=0
        int dispOff = _code.Count - 4;
        _pendingFixups.Add((dispOff, 4, "str_" + stringIdx));
    }

    // CALL through IAT via [rip+iatOffset]
    private void EmitIatCall(int importIdx)
    {
        // FF 15 rel32 — call [rip+disp]
        _code.Add(0xFF);
        _code.Add(0x15);
        int fixOff = _code.Count;
        _code.AddRange(new byte[4]); // placeholder
        _pendingFixups.Add((fixOff, 4, "iat_" + importIdx));
    }

    // Win32 call with single int arg
    private void EmitWin32Call(int importIdx, int arg)
    {
        if (arg == 0)
            EmitXorReg(Reg.RCX);
        else
            Emit(OpCode.MOV_R64_IMM64, R(Reg.RCX), Imm(arg));
        ShadowCall(importIdx);
    }

    private void ShadowCall(int importIdx)
    {
        Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(40));
        EmitIatCall(importIdx);
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(40));
    }

    // ── Multi-byte NOP (up to 9 bytes) ──
    private static ReadOnlySpan<byte> Nop9 => new byte[] { 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 };
    private static ReadOnlySpan<byte> Nop8 => new byte[] { 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 };
    private static ReadOnlySpan<byte> Nop7 => new byte[] { 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 };
    private static ReadOnlySpan<byte> Nop6 => new byte[] { 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 };
    private static ReadOnlySpan<byte> Nop5 => new byte[] { 0x0F, 0x1F, 0x44, 0x00, 0x00 };
    private static ReadOnlySpan<byte> Nop4 => new byte[] { 0x0F, 0x1F, 0x40, 0x00 };
    private static ReadOnlySpan<byte> Nop3 => new byte[] { 0x0F, 0x1F, 0x00 };
    private static ReadOnlySpan<byte> Nop2 => new byte[] { 0x66, 0x90 };

    private void EmitNop(int count)
    {
        while (count >= 9) { _code.AddRange(Nop9); count -= 9; }
        if (count >= 8) { _code.AddRange(Nop8); count -= 8; }
        if (count >= 7) { _code.AddRange(Nop7); count -= 7; }
        if (count >= 6) { _code.AddRange(Nop6); count -= 6; }
        if (count >= 5) { _code.AddRange(Nop5); count -= 5; }
        if (count >= 4) { _code.AddRange(Nop4); count -= 4; }
        if (count >= 3) { _code.AddRange(Nop3); count -= 3; }
        if (count >= 2) { _code.AddRange(Nop2); count -= 2; }
        if (count >= 1) { _code.Add(0x90); }
    }

    // ── CPUID helpers ──
    private void EmitCpuidRaw() => _code.AddRange(new byte[] { 0x0F, 0xA2 });
    private void EmitShiftRight24() => _code.AddRange(new byte[] { 0xC1, 0xE8, 0x18 }); // SHR EAX, 24

    // ── P/E-core affinity init ──
    // At startup: detect core type via CPUID leaf 0x1A, then pin to appropriate cores
    private void EmitAffinityInit()
    {
        bool hasHotStates = _program.States.Any(s => (s.HotWeight ?? 0.5) >= 0.8);
        int coreCount = Environment.ProcessorCount;

        // CPUID leaf 0x1A — read core type from EAX[31:24]
        EmitMovRegImm32(Reg.RAX, 0x1A);
        EmitCpuidRaw();
        EmitShiftRight24();                          // EAX = core type (0x20=E, 0x40=P, 0=unknown)
        Emit(OpCode.MOV_MEM_R32, Mem(Reg.RBP, _offCoreType), R(Reg.RAX));

        // Build affinity masks (compile-time heuristic)
        long pCoreMask = coreCount >= 4 ? (1L << (coreCount / 2)) - 1 : -1L;
        long eCoreMask = coreCount >= 4 ? ((1L << coreCount) - 1) ^ pCoreMask : -1L;
        long mask = hasHotStates ? pCoreMask : eCoreMask;

        // GetCurrentThread → RCX
        ShadowCall(IdxGetCurrentThread);
        Emit(OpCode.MOV_R64_R64, R(Reg.RCX), R(Reg.RAX));

        // Load mask → RDX, call SetThreadAffinityMask(thread, mask)
        EmitLoadImm(Reg.RDX, mask);
        ShadowCall(IdxSetThreadAffinityMask);
    }

    // ── Compact instruction helpers ──

    // XOR reg32, reg32 — 2 bytes (reg 0-7) or 3 bytes (reg 8-15)
    private void EmitXorReg(int reg)
    {
        if (reg >= 8)
            _code.Add(0x45); // REX.RB
        _code.Add(0x33);
        _code.Add((byte)(0xC0 + (reg & 7) * 9));
    }

    // INC r64 — 3 bytes
    private void EmitInc(int reg)
    {
        _code.Add((byte)(0x48 + ((reg >> 3) & 1)));
        _code.Add(0xFF);
        _code.Add((byte)(0xC0 + (reg & 7)));
    }

    // DEC r64 — 3 bytes
    private void EmitDec(int reg)
    {
        _code.Add((byte)(0x48 + ((reg >> 3) & 1)));
        _code.Add(0xFF);
        _code.Add((byte)(0xC8 + (reg & 7)));
    }

    // MOV r32, imm32 — 5 bytes (reg 0-7) or 6 bytes (reg 8-15)
    private void EmitMovRegImm32(int reg, uint imm)
    {
        if (reg >= 8)
            _code.Add(0x41); // REX.B
        _code.Add((byte)(0xB8 + (reg & 7)));
        _code.AddRange(BitConverter.GetBytes(imm));
    }

    // Load small constant into register — auto-picks smallest encoding
    private void EmitLoadImm(int reg, long val)
    {
        if (val == 0)
            EmitXorReg(reg);
        else if (val > 0 && val <= int.MaxValue)
            EmitMovRegImm32(reg, (uint)val);
        else
            Emit(OpCode.MOV_R64_IMM64, R(reg), Imm(val));
    }

    // Align current position to 32-byte boundary with NOP padding
    private void AlignTo32()
    {
        int mod = _code.Count % 32;
        if (mod != 0)
            EmitNop(32 - mod);
    }

    // Align current position to 16-byte boundary with NOP padding
    private void AlignTo16()
    {
        int mod = _code.Count % 16;
        if (mod != 0)
            EmitNop(16 - mod);
    }

    // Align current position to 64-byte boundary with NOP padding
    private void AlignTo64()
    {
        int mod = _code.Count % 64;
        if (mod != 0)
            EmitNop(64 - mod);
    }

    // ── Cache pyramid: prefetch at appropriate level ──
    //
    //  @cache(L1)  → PREFETCHT0  (L1 + L2 + L3)
    //  @cache(L2)  → PREFETCHT1  (L2 + L3, skip L1)
    //  @cache(L3)  → PREFETCHT2  (L3 only)
    //  cold (≤0.3) → PREFETCHNTA (non-temporal, evict)
    //
    private void EmitPrefetchData(int stackOffset, int level)
    {
        _code.Add(0x0F);
        _code.Add(0x18);
        // reg field: 0=NTA, 1=T0, 2=T1, 3=T2
        int reg = level switch { 0 => 0, 1 => 1, 2 => 2, 3 => 3, _ => 1 };
        if (stackOffset >= sbyte.MinValue && stackOffset <= sbyte.MaxValue)
        {
            _code.Add((byte)(0x45 + (reg << 3))); // mod=01, reg, rm=101
            _code.Add((byte)(sbyte)stackOffset);
        }
        else
        {
            _code.Add((byte)(0x85 + (reg << 3))); // mod=10, reg, rm=101
            _code.AddRange(BitConverter.GetBytes(stackOffset));
        }
    }

    // Shorthand: prefetch to L1
    private void EmitPrefetchL1(int stackOffset) => EmitPrefetchData(stackOffset, 1);

    // Prefetch target state's variables at cache level matching its @cache policy
    private void EmitPrefetchForTransition(TransitionNode t)
    {
        int ti = FindStateIndex(t.Target);
        var targetState = _program.States[ti];
        int level = targetState.CachePolicy switch
        {
            "L1" => 1,
            "L2" => 2,
            "L3" => 3,
            _ => 0 // NTA
        };
        if (_stateVars.TryGetValue(t.Target, out var vars))
        {
            foreach (var sv in vars)
                EmitPrefetchData(sv.StackOffset, level);
        }
        // Prefetch enter code at matching level (L1 code → T0, L2 code → T1)
        if (level > 0)
            EmitPrefetch("en_" + ti, level);
    }

    // Full pyramid-aware prefetch: uses HotWeight + @cache to pick level
    private void EmitPrefetchForTransitionCacheAware(TransitionNode t)
    {
        var hw = t.HotWeight ?? 0.5;
        int ti = FindStateIndex(t.Target);
        var targetState = _program.States[ti];
        int level;
        if (hw >= 0.8)
            level = 1; // T0 → L1
        else if (hw >= 0.4)
            level = 2; // T1 → L2
        else
            level = 0; // NTA → evict

        if (_stateVars.TryGetValue(t.Target, out var vars))
        {
            foreach (var sv in vars)
                EmitPrefetchData(sv.StackOffset, level);
        }
        // Prefetch enter code at matching cache level
        EmitPrefetch("en_" + ti, level > 0 ? level : 1);
    }

    // Code prefetch at specified cache level: 1=L1, 2=L2, 3=L3
    private void EmitPrefetch(string targetLabel, int level = 1)
    {
        var op = level switch
        {
            2 => OpCode.PREFETCHT1_RIPREL,
            3 => OpCode.PREFETCHT2_RIPREL,
            _ => OpCode.PREFETCHT0_RIPREL,
        };
        Emit(op, Imm(0));
        _pendingFixups.Add((_code.Count - 4, 4, targetLabel));
    }

    // Non-temporal prefetch for cold (≤0.3) state variables — evict from L1
    private void EmitPrefetchColdData(StateDefNode state)
    {
        if ((state.HotWeight ?? 0.5) <= 0.3 && state.CachePolicy != "L1")
        {
            if (_stateVars.TryGetValue(state.Name, out var vars))
                foreach (var sv in vars)
                    EmitPrefetchData(sv.StackOffset, 0); // NTA
        }
    }

    // Apply padding to avoid L1i cache set collisions (8-way, 4KB per way)
    private void PadForCacheAssociativity()
    {
        var hotEntries = _stateCodeBounds
            .Where(kv => (_program.States[kv.Key].HotWeight ?? 0) >= 0.8)
            .Select(kv => (origIdx: kv.Key, offset: kv.Value.start, origEnd: kv.Value.end))
            .ToList();

        var setOccupancy = new Dictionary<int, int>();
        foreach (var (origIdx, offset, origEnd) in hotEntries)
        {
            int set = offset % 4096;
            setOccupancy.TryGetValue(set, out int count);
            if (count >= 8)
            {
                int pad = 4096 - (offset % 4096);
                if (pad == 4096) pad = 0;
                EmitNop(pad);
                int origSize = origEnd - offset;
                int newOff = _code.Count;
                _labels["en_" + origIdx] = newOff;
                _stateCodeBounds[origIdx] = (newOff, newOff + origSize);
                set = 0;
                count = 0;
            }
            setOccupancy[set] = count + 1;
        }
    }

    // Cache budget checks: L1i (32KB), L1d (48KB for @cache(L1) data), DSB/Op-Cache µops
    private void EmitCacheBudgetChecks()
    {
        int reDispStart = _labels.GetValueOrDefault("re_dispatch", 0);
        int adStart = _labels.GetValueOrDefault("advance_cursor", 0);
        int loopEnd = (adStart > reDispStart) ? adStart : _code.Count;
        int loopBytes = Math.Max(0, loopEnd - reDispStart);

        // Total hot enter code
        int hotEnterBytes = 0;
        foreach (var kv in _stateCodeBounds)
        {
            if ((_program.States[kv.Key].HotWeight ?? 0) >= 0.8)
                hotEnterBytes += kv.Value.end - kv.Value.start;
        }

        int totalHotCode = loopBytes + hotEnterBytes;
        // Embed warnings as ASCII strings in the code (harmless data)
        if (totalHotCode > 24576) // warn at 75% of L1i
        {
            string w = $"; L1i: hot {totalHotCode}B > 75% of 32KB";
            foreach (char c in w) _code.Add((byte)c);
            _code.Add(0);
        }

        // DSB µop estimate (rough: 3 bytes/instr × 1.2 µops/instr)
        int estUops = loopBytes / 3;
        if (estUops > 3500)
        {
            string w = $"; DSB: ~{estUops} µops > 85% of 4096";
            foreach (char c in w) _code.Add((byte)c);
            _code.Add(0);
        }

        // L1d data budget for @cache(L1) vars
        if (_stateVars.Values.Any(sv => sv.Count > 0))
        {
            int l1VarBytes = 0;
            foreach (var state in _program.States.Where(s => s.CachePolicy == "L1"))
                if (_stateVars.TryGetValue(state.Name, out var sv))
                    l1VarBytes += sv.Count * 8;
            if (l1VarBytes > 49152)
            {
                string w = $"; L1d: @cache(L1) vars {l1VarBytes}B > 48KB";
                foreach (char c in w) _code.Add((byte)c);
                _code.Add(0);
            }
        }
    }

    // ── Parse number (with simple arithmetic) ──
    private long ParseNumber(string s)
    {
        if (string.IsNullOrEmpty(s)) return 0;
        s = s.Trim();
        if (s.StartsWith("0x") && long.TryParse(s.Substring(2), System.Globalization.NumberStyles.HexNumber, null, out long hx))
            return hx;
        string[] ops = { " - ", " + ", " * " };
        foreach (var op in ops)
        {
            int idx = s.IndexOf(op, StringComparison.Ordinal);
            if (idx > 0)
            {
                var parts = s.Split(new[] { op }, StringSplitOptions.None);
                if (parts.Length == 2 &&
                    long.TryParse(parts[0].Trim(), out long a) &&
                    long.TryParse(parts[1].Trim(), out long b))
                {
                    switch (op.Trim())
                    {
                        case "-": return a - b;
                        case "+": return a + b;
                        case "*": return a * b;
                    }
                }
            }
        }
        if (long.TryParse(s, out long i)) return i;
        return 0;
    }

    // ── Misc ──
    private int FindStateIndex(string name)
    {
        for (int i = 0; i < _stateNames.Count; i++)
            if (string.Equals(_stateNames[i], name, StringComparison.OrdinalIgnoreCase))
                return i;
        return 0;
    }

    private static Operand R(int r) => Operand.R(r);
    private static Operand Imm(long v) => Operand.Imm(v);
    private static Operand ImmU32(uint v) => Operand.ImmU32(v);
    private static Operand Mem(int baseReg, int disp) => Operand.Mem(baseReg, disp);

    private void Emit(OpCode op, params Operand[] operands)
    {
        X64Encoder.Emit(_code, op, operands);
    }

    public string DisassembleAndWrite(string path)
    {
        var all = _code.ToArray();
        File.WriteAllBytes(path, all);
        return X64Encoder.Disassemble(all);
    }

    private class ContextVarInfo
    {
        public string Name { get; set; } = "";
        public string Type { get; set; } = "";
        public string DefaultValue { get; set; } = "0";
    }

    private class StateVarInfo
    {
        public string Name { get; set; } = "";
        public string Type { get; set; } = "";
        public string DefaultValue { get; set; } = "0";
        public int StackOffset { get; set; }
        public int Size { get; set; }
    }

    private static int GetTypeSize(string type)
    {
        return type.ToLowerInvariant() switch
        {
            "int8" or "byte" or "u8" or "bool" => 1,
            "int16" or "short" or "half" or "u16" => 2,
            "int32" or "int" or "uint" or "float" => 4,
            "int64" or "long" or "double" or "uint64" => 8,
            _ => 8
        };
    }

    private static int GetTypeAlign(string type)
    {
        int s = GetTypeSize(type);
        return s <= 4 ? s : 8; // align to natural size, but never more than 8
    }

    private void EmitLoadVarToReg(int reg, int vo, int size)
    {
        switch (size)
        {
            case 1:
                Emit(OpCode.MOVZX_R64_MEM8, R(reg), Mem(Reg.RBP, vo));
                break;
            case 2:
                Emit(OpCode.MOVZX_R64_MEM16, R(reg), Mem(Reg.RBP, vo));
                break;
            case 4:
                Emit(OpCode.MOV_R32_MEM, R(reg), Mem(Reg.RBP, vo));
                break;
            default:
                Emit(OpCode.MOV_R64_MEM, R(reg), Mem(Reg.RBP, vo));
                break;
        }
    }

    private void EmitStoreVarFromReg(int vo, int reg, int size)
    {
        switch (size)
        {
            case 1:
                Emit(OpCode.MOV_MEM_R8, Mem(Reg.RBP, vo), R(reg));
                break;
            case 2:
                Emit(OpCode.MOV_MEM_R16, Mem(Reg.RBP, vo), R(reg));
                break;
            case 4:
                Emit(OpCode.MOV_MEM_R32, Mem(Reg.RBP, vo), R(reg));
                break;
            default:
                Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, vo), R(reg));
                break;
        }
    }

    public static (byte[] code, int dataSize) GenerateBenchmarkLoop(int iterations, int innerOps, int cacheKB)
    {
        var code = new List<byte>();

        X64Encoder.Emit(code, OpCode.PUSH_R64, Operand.R(Reg.RBP));
        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.RBP), Operand.R(Reg.RSP));
        X64Encoder.Emit(code, OpCode.SUB_R64_IMM32, Operand.R(Reg.RSP), Operand.ImmU32(0x30));

        int arrSize = cacheKB * 1024 / 8;
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RAX), Operand.Imm(iterations));
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R10), Operand.Imm(innerOps));
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R11), Operand.Imm(arrSize));

        int outer = code.Count;
        // XOR r32,r32 — zero RBX, R12, R13
        code.Add(0x33); code.Add(0xDB);                         // XOR EBX, EBX
        code.Add(0x45); code.Add(0x33); code.Add(0xE4);         // XOR R12D, R12D

        int inner = code.Count;
        code.Add(0x45); code.Add(0x33); code.Add(0xED);         // XOR R13D, R13D

        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.R14), Operand.R(Reg.R13));
        X64Encoder.Emit(code, OpCode.AND_R64_R64, Operand.R(Reg.R14), Operand.R(Reg.R11));

        int loadAddr = code.Count;
        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.R15), Operand.R(Reg.R14));
        // INC R12 — 3 bytes
        code.Add(0x4D); code.Add(0xFF); code.Add(0xC4);         // INC R12
        X64Encoder.Emit(code, OpCode.CMP_R64_R64, Operand.R(Reg.R12), Operand.R(Reg.R10));
        X64Encoder.Emit(code, OpCode.JNE_REL8, Operand.Imm((sbyte)(inner - code.Count - 2)));

        // INC RBX — 3 bytes
        code.Add(0x48); code.Add(0xFF); code.Add(0xC3);         // INC RBX
        // DEC RAX — 3 bytes
        code.Add(0x48); code.Add(0xFF); code.Add(0xC8);         // DEC RAX
        X64Encoder.Emit(code, OpCode.JNE_REL8, Operand.Imm((sbyte)(outer - code.Count - 2)));

        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.RAX), Operand.R(Reg.RBX));
        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RSP), Operand.ImmU32(0x30));
        X64Encoder.Emit(code, OpCode.POP_R64, Operand.R(Reg.RBP));
        X64Encoder.Emit(code, OpCode.RET);

        return (code.ToArray(), arrSize * 8);
    }
}
