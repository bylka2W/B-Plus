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

    private static readonly string[] ImportFns = { "GetStdHandle", "WriteConsoleA", "ReadFile", "ExitProcess" };
    private const int IdxGetStdHandle = 0;
    private const int IdxWriteConsoleA = 1;
    private const int IdxReadFile = 2;
    private const int IdxExitProcess = 3;
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
        EmitEventLoop();
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
        _offCharsRead   = off; off -= 4;
        _offCharsWritten = off; off -= 4;
        _offCurState = off; off -= 8;
        _offCursor   = off; off -= 8;   // current read cursor in buffer
        _offRemaining = off; off -= 8;  // remaining bytes in buffer
        // Context variables (before buffer, below curState/remaining)
        _offCtxVarStart = off;
        foreach (var _ in _ctxVars)
            off -= 8;
        // Input buffer at the bottom
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
            Emit(OpCode.MOV_R64_IMM64, R(Reg.RAX), Imm(val));
            Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, off), R(Reg.RAX));
            off -= 8;
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
        for (int i = 0; i < _program.States.Count; i++)
        {
            _labels["en_" + i] = _code.Count;
            var state = _program.States[i];
            foreach (var act in state.Actions.Where(a => a.Type == ActionType.Enter))
                EmitAction(act.Body);
            Emit(OpCode.RET);
        }
    }

    // ── Event loop ──
    private void EmitEventLoop()
    {
        _labels["evloop"] = _code.Count;

        // ReadFile(hStdIn, buf, BufSize, &charsRead, null)
        Emit(OpCode.MOV_R64_MEM,  R(Reg.RCX), Mem(Reg.RBP, _offHStdIn));
        Emit(OpCode.LEA_R64_MEM,  R(Reg.RDX), Mem(Reg.RBP, _offBuf));
        Emit(OpCode.MOV_R64_IMM64, R(Reg.R8),  Imm(BufSize));
        Emit(OpCode.LEA_R64_MEM,  R(Reg.R9),  Mem(Reg.RBP, _offCharsRead));
        Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(40)); // shadow + 5th arg
        Emit(OpCode.MOV_R64_IMM64, R(Reg.RAX), Imm(0));
        Emit(OpCode.MOV_MEM_R64,   Mem(Reg.RSP, 32), R(Reg.RAX)); // overlapped = NULL
        EmitIatCall(IdxReadFile);
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(40));

        // If ReadFile failed (EOF/error), exit
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");

        // Initialize cursor = 0, remaining = charsRead
        Emit(OpCode.XOR_R64_R64, R(Reg.RAX), R(Reg.RAX));
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offCursor), R(Reg.RAX));
        Emit(OpCode.MOV_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCharsRead));
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offRemaining), R(Reg.RAX));

        // ── Re-dispatch entry: skip ReadFile, process remaining buffer ──
        _labels["re_dispatch"] = _code.Count;

        // If remaining == 0, no more data in buffer → read more
        Emit(OpCode.MOV_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, _offRemaining));
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "evloop");

        // ── "exit" check at cursor position ──
        int exIdx = AddPoolString("exit");
        EmitRipLea(Reg.RSI, exIdx);
        Emit(OpCode.LEA_R64_MEM, R(Reg.RDI), Mem(Reg.RBP, _offBuf));
        Emit(OpCode.MOV_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCursor));
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
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RDI), ImmU32(1));
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RSI), ImmU32(1));
        EmitShortJmp(OpCode.JMP_REL8, exLp);
        _labels[exCe] = _code.Count;
        Emit(OpCode.TEST_R64_R64, R(Reg.RBX), R(Reg.RBX));
        EmitShortJmp(OpCode.JNE_REL8, "no_exit");
        Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0A));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");
        Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0D));
        EmitCondLongJmp(OpCode.JE_REL32, "exit_process");
        EmitShortJmp(OpCode.JMP_REL8, "no_exit");
        _labels["no_exit"] = _code.Count;

        // Load current_state into R12
        Emit(OpCode.MOV_R64_MEM, R(Reg.R12), Mem(Reg.RBP, _offCurState));

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
            _labels["dp_" + si] = _code.Count;
            EmitStateDispatch(_program.States[si], si);
            // No transition matched → advance past this line, re-dispatch
            EmitLongJmp("advance_cursor");
        }

        // Safety fallback
        EmitLongJmp("advance_cursor");

        // ── Advance cursor past current line (shared snippet) ──
        _labels["advance_cursor"] = _code.Count;

        // RDI = buf_start + cursor (current line start)
        Emit(OpCode.LEA_R64_MEM, R(Reg.RDI), Mem(Reg.RBP, _offBuf));
        Emit(OpCode.MOV_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCursor));
        Emit(OpCode.ADD_R64_R64, R(Reg.RDI), R(Reg.RAX));
        // RBX = old cursor (save for delta computation)
        Emit(OpCode.MOV_R64_R64, R(Reg.RBX), R(Reg.RAX));
        // RCX = remaining (scan limit)
        Emit(OpCode.MOV_R64_IMM64, R(Reg.RCX), Imm(0));
        Emit(OpCode.MOV_R64_MEM, R(Reg.RCX), Mem(Reg.RBP, _offRemaining));

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
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RDI), ImmU32(1));
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RCX), ImmU32(0xFFFFFFFF)); // decrement
        EmitShortJmp(OpCode.JMP_REL8, advScan);

        _labels[advCr] = _code.Count;
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RDI), ImmU32(1));  // skip \r
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RCX), ImmU32(0xFFFFFFFF));
        EmitShortJmp(OpCode.JE_REL8, advDone);               // RCX hit 0
        Emit(OpCode.CMP_R64_IMM8, Mem(Reg.RDI, 0), ImmU32(0x0A));
        EmitShortJmp(OpCode.JNE_REL8, advDone);              // not CRLF → done
        // fall through to adv_found to handle \n after \r
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RDI), ImmU32(1));  // skip \n in CRLF
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RCX), ImmU32(0xFFFFFFFF));

        _labels[advFound] = _code.Count;
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RDI), ImmU32(1));  // skip terminator
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RCX), ImmU32(0xFFFFFFFF));

        _labels[advDone] = _code.Count;
        // RDI = absolute position after consumed line's terminator
        // Compute new_cursor = RDI - (RBP + _offBuf)
        Emit(OpCode.LEA_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, _offBuf));
        Emit(OpCode.SUB_R64_R64, R(Reg.RDI), R(Reg.RAX));
        // RAX = consumed = new_cursor - old_cursor
        Emit(OpCode.MOV_R64_R64, R(Reg.RAX), R(Reg.RDI));
        Emit(OpCode.SUB_R64_R64, R(Reg.RAX), R(Reg.RBX));
        // _offRemaining -= consumed
        Emit(OpCode.MOV_R64_MEM, R(Reg.RCX), Mem(Reg.RBP, _offRemaining));
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
        // Always/auto transitions (no event name) execute unconditionally
        foreach (var t in state.Transitions)
        {
            if (string.IsNullOrEmpty(t.EventName) && !t.IsAlways)
                continue;
            if (t.IsAlways && string.IsNullOrEmpty(t.EventName))
            {
                EmitGuardSkip(t.Guard, si, -1);
                if (!string.IsNullOrEmpty(t.Body))
                    EmitAction(t.Body);
                ChangeToState(t.Target);
                return;
            }
        }

        // Event-driven transitions
        var trans = state.Transitions
            .Where(t => !string.IsNullOrEmpty(t.EventName))
            .ToList();

        for (int ti = 0; ti < trans.Count; ti++)
        {
            var t = trans[ti];
            string skipLabel = $"sk_{si}_{ti}"; // points to next transition or fallback

            // Emit string comparison: buffer vs event name
            int strOff = AddPoolString(t.EventName);
            int cmpLen = t.EventName.Length;

            // rsi = RIP-relative address of event string
            EmitRipLea(Reg.RSI, strOff);
            // rdi = buffer address + cursor
            Emit(OpCode.LEA_R64_MEM, R(Reg.RDI), Mem(Reg.RBP, _offBuf));
            Emit(OpCode.MOV_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, _offCursor));
            Emit(OpCode.ADD_R64_R64, R(Reg.RDI), R(Reg.RAX));

            // Compare loop
            string loopLabel = $"lp_{si}_{ti}";
            string checkEventEnd = $"ce_{si}_{ti}";
            _labels[loopLabel] = _code.Count;
            Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RAX), Mem(Reg.RDI, 0));
            Emit(OpCode.MOVZX_R64_MEM8, R(Reg.RBX), Mem(Reg.RSI, 0));
            Emit(OpCode.CMP_R64_R64, R(Reg.RAX), R(Reg.RBX));
            // If bytes differ, check if event ended (bl=0) and input is terminator
            EmitShortJmp(OpCode.JNE_REL8, checkEventEnd);
            // If both zero, match
            Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
            EmitShortJmp(OpCode.JE_REL8, $"mt_{si}_{ti}");
            // Advance and loop
            Emit(OpCode.ADD_R64_IMM32, R(Reg.RDI), ImmU32(1));
            Emit(OpCode.ADD_R64_IMM32, R(Reg.RSI), ImmU32(1));
            EmitShortJmp(OpCode.JMP_REL8, loopLabel);

            // Check if event ended (rbx == 0) and input is null/newline → match
            _labels[checkEventEnd] = _code.Count;
            Emit(OpCode.TEST_R64_R64, R(Reg.RBX), R(Reg.RBX));
            EmitShortJmp(OpCode.JNE_REL8, skipLabel);   // event byte nonzero → real mismatch
            // Event ended: accept null, \n, \r in input
            Emit(OpCode.TEST_R64_R64, R(Reg.RAX), R(Reg.RAX));
            EmitShortJmp(OpCode.JE_REL8, $"mt_{si}_{ti}");
            Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0A));
            EmitShortJmp(OpCode.JE_REL8, $"mt_{si}_{ti}");
            Emit(OpCode.CMP_R64_IMM32, R(Reg.RAX), ImmU32(0x0D));
            EmitShortJmp(OpCode.JE_REL8, $"mt_{si}_{ti}");
            // Not a terminator → skip transition
            EmitShortJmp(OpCode.JMP_REL8, skipLabel);

            // Match label
            _labels[$"mt_{si}_{ti}"] = _code.Count;

            // Guard check: skip to next transition if guard fails
            EmitGuardSkip(t.Guard, si, ti);

            // Execute body
            if (!string.IsNullOrEmpty(t.Body))
                EmitAction(t.Body);

            // Change state + enter new state + loop
            ChangeToState(t.Target);

            // Skip label — next transition starts here
            _labels[skipLabel] = _code.Count;
        }

        // If no transition matched, just loop
        // (skip label for last transition already points here)
    }

    // ── Guard handling ──
    private void EmitGuardSkip(string? guard, int si, int ti)
    {
        if (string.IsNullOrEmpty(guard)) return;

        string skipLabel = $"sk_{si}_{ti}"; // same skip target as transition mismatch

        var (lhs, op, rhs) = ParseGuard(guard);

        // Load lhs
        int ci = _ctxVars.FindIndex(v => v.Name == lhs);
        if (ci >= 0)
        {
            int vo = _offCtxVarStart - ci * 8;
            Emit(OpCode.MOV_R64_MEM, R(Reg.RAX), Mem(Reg.RBP, vo));
        }
        else if (long.TryParse(lhs, out long lv))
            Emit(OpCode.MOV_R64_IMM64, R(Reg.RAX), Imm(lv));
        else
            Emit(OpCode.XOR_R64_R64, R(Reg.RAX), R(Reg.RAX));

        // Load rhs
        int cj = _ctxVars.FindIndex(v => v.Name == rhs);
        if (cj >= 0)
        {
            int vo = _offCtxVarStart - cj * 8;
            Emit(OpCode.MOV_R64_MEM, R(Reg.RBX), Mem(Reg.RBP, vo));
        }
        else if (long.TryParse(rhs, out long rv))
            Emit(OpCode.MOV_R64_IMM64, R(Reg.RBX), Imm(rv));
        else
            Emit(OpCode.XOR_R64_R64, R(Reg.RBX), R(Reg.RBX));

        Emit(OpCode.CMP_R64_R64, R(Reg.RAX), R(Reg.RBX));

        switch (op)
        {
            case ">" : EmitShortJmp(OpCode.JLE_REL8, skipLabel); break;
            case "<" : EmitShortJmp(OpCode.JGE_REL8, skipLabel); break;
            case ">=": EmitShortJmp(OpCode.JL_REL8,  skipLabel); break;
            case "<=": EmitShortJmp(OpCode.JG_REL8,  skipLabel); break;
            case "==": EmitShortJmp(OpCode.JNE_REL8, skipLabel); break;
            case "!=": EmitShortJmp(OpCode.JE_REL8,  skipLabel); break;
        }
    }

    // ── State change ──
    private void ChangeToState(string targetName)
    {
        int ti = FindStateIndex(targetName);
        // current_state = ti
        Emit(OpCode.MOV_R64_IMM64, R(Reg.RAX), Imm(ti));
        Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, _offCurState), R(Reg.RAX));
        // call enter_{ti}
        EmitCallToLabel("en_" + ti);
        // advance cursor and re-dispatch remaining buffer content
        EmitLongJmp("advance_cursor");
    }

    // ── Action emission ──
    private void EmitAction(string? body)
    {
        if (string.IsNullOrEmpty(body)) return;
        body = body.Trim();

        // print("...")
        if (body.StartsWith("print(") && body.EndsWith(")"))
        {
            string content = body.Substring(6, body.Length - 7).Trim().Trim('"');
            if (string.IsNullOrEmpty(content)) return;
            int strOff = AddPoolString(content);

            Emit(OpCode.MOV_R64_MEM,    R(Reg.RCX), Mem(Reg.RBP, _offHStdOut));
            EmitRipLea(Reg.RDX, strOff);
            Emit(OpCode.MOV_R64_IMM64,  R(Reg.R8),  Imm(content.Length));
            Emit(OpCode.LEA_R64_MEM,    R(Reg.R9),  Mem(Reg.RBP, _offCharsWritten));
            Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(40)); // shadow + 5th arg
            Emit(OpCode.MOV_R64_IMM64,  R(Reg.RAX), Imm(0));
            Emit(OpCode.MOV_MEM_R64,    Mem(Reg.RSP, 32), R(Reg.RAX)); // 5th arg at safe offset
            EmitIatCall(IdxWriteConsoleA);
            Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(40));
            return;
        }

        // Assignment: var = expr
        int eq = body.IndexOf('=');
        if (eq > 0)
        {
            string varName = body.Substring(0, eq).Trim();
            string expr = body.Substring(eq + 1).Trim();
            int ci = _ctxVars.FindIndex(v => v.Name == varName);
            if (ci >= 0)
            {
                long val = ParseNumber(expr);
                int vo = _offCtxVarStart - ci * 8;
                Emit(OpCode.MOV_R64_IMM64, R(Reg.RAX), Imm(val));
                Emit(OpCode.MOV_MEM_R64, Mem(Reg.RBP, vo), R(Reg.RAX));
            }
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
        Emit(OpCode.MOV_R64_IMM64, R(Reg.RCX), Imm(arg));
        ShadowCall(importIdx);
    }

    private void ShadowCall(int importIdx)
    {
        Emit(OpCode.SUB_R64_IMM32, R(Reg.RSP), ImmU32(32));
        EmitIatCall(importIdx);
        Emit(OpCode.ADD_R64_IMM32, R(Reg.RSP), ImmU32(32));
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
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RBX), Operand.Imm(0));
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R12), Operand.Imm(0));

        int inner = code.Count;
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R13), Operand.Imm(0));

        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.R14), Operand.R(Reg.R13));
        X64Encoder.Emit(code, OpCode.AND_R64_R64, Operand.R(Reg.R14), Operand.R(Reg.R11));

        int loadAddr = code.Count;
        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.R15), Operand.R(Reg.R14));
        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.R12), Operand.ImmU32(1));
        X64Encoder.Emit(code, OpCode.CMP_R64_R64, Operand.R(Reg.R12), Operand.R(Reg.R10));
        X64Encoder.Emit(code, OpCode.JNE_REL8, Operand.Imm((sbyte)(inner - code.Count - 2)));

        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RBX), Operand.ImmU32(1));
        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RAX), Operand.ImmU32(0xFFFFFFFF));
        X64Encoder.Emit(code, OpCode.JNE_REL8, Operand.Imm((sbyte)(outer - code.Count - 2)));

        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.RAX), Operand.R(Reg.RBX));
        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RSP), Operand.ImmU32(0x30));
        X64Encoder.Emit(code, OpCode.POP_R64, Operand.R(Reg.RBP));
        X64Encoder.Emit(code, OpCode.RET);

        return (code.ToArray(), arrSize * 8);
    }
}
