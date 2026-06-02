using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace BPlus.Core.Algorithm;

public class ASTToMachineCode
{
    private X64Encoder enc = new();
    private AbiDispatcher abi = new();
    private Dictionary<string, long> symbols = new();
    private Dictionary<string, int> locals = new();
    private Dictionary<string, int> labels = new();
    private List<long> jmpLocations = new();
    private int localOffset = 8;
    private AbiType currentAbi = AbiType.Windows;

    public class CompileResult
    {
        public byte[] Code { get; set; } = Array.Empty<byte>();
        public Dictionary<string, long> Symbols { get; set; } = new();
        public List<string> Errors { get; set; } = new();
        public int Instructions { get; set; }
        public double EstCycles { get; set; }
    }

    public CompileResult Compile(List<ASTNode> ast, AbiType abiType = AbiType.Windows)
    {
        var result = new CompileResult();
        currentAbi = abiType;
        enc = new X64Encoder();
        symbols.Clear();
        locals.Clear();
        labels.Clear();
        jmpLocations.Clear();
        localOffset = 8;

        foreach (var node in ast)
        {
            if (node is FunctionDef func)
            {
                CompileFunction(func, result);
            }
        }

        ApplyPatches(result);
        result.Code = enc.Code;
        result.Symbols = new Dictionary<string, long>(symbols);
        result.Instructions = enc.Length;
        result.EstCycles = enc.Length * 0.5;
        return result;
    }

    private void CompileFunction(FunctionDef func, CompileResult result)
    {
        int localsSize = EstimateLocalsSize(func.Body);
        symbols[func.Name] = enc.BaseAddress + enc.Length;

        var prologue = GeneratePrologue(localsSize);
        EmitAsm(prologue);

        foreach (var stmt in func.Body)
        {
            CompileStatement(stmt, result);
        }

        var epilogue = GenerateEpilogue(localsSize);
        EmitAsm(epilogue);
    }

    private void CompileStatement(ASTNode stmt, CompileResult result)
    {
        switch (stmt)
        {
            case VariableDecl decl:
                CompileVarDecl(decl);
                break;
            case Assignment assign:
                CompileAssignment(assign);
                break;
            case IfStatement ifStmt:
                CompileIf(ifStmt, result);
                break;
            case WhileStatement whileStmt:
                CompileWhile(whileStmt, result);
                break;
            case ReturnStatement ret:
                CompileReturn(ret);
                break;
            case ExprStatement expr:
                CompileExpr(expr.Expr);
                break;
            case OnEventStatement on:
                CompileOnEvent(on);
                break;
            case EnterStatement enter:
                CompileEnter(enter);
                break;
        }
    }

    private void CompileVarDecl(VariableDecl decl)
    {
        if (decl.Init != null)
        {
            CompileExpr(decl.Init);
        }
        locals[decl.Name] = localOffset;
        localOffset += 8;
    }

    private void CompileAssignment(Assignment assign)
    {
        var value = EvalImmediate(assign.Value);
        if (value.HasValue)
        {
            if (locals.TryGetValue(assign.Target, out int offset))
            {
                enc.Mov(3, offset - localOffset + 8, 8);
                enc.Mov(8, offset - localOffset + 8, (int)value.Value);
            }
        }
        else
        {
            CompileExpr(assign.Value);
        }
    }

    private void CompileIf(IfStatement ifStmt, CompileResult result)
    {
        CompileCondition(ifStmt.Condition);

        string elseLabel = GenLabel();
        int jneLoc = enc.Length;
        enc.Je(0);

        foreach (var stmt in ifStmt.ThenBlock)
            CompileStatement(stmt, result);

        if (ifStmt.ElseBlock.Count > 0)
        {
            int jmpEnd = enc.Length;
            enc.Jmp(0);

            enc.Mov(3, 0);
            enc.Je(ifStmt.ThenBlock.Count * 10);
        }
        else
        {
            int offset = enc.Length - jneLoc;
            PatchJump(jneLoc, offset);
        }

        foreach (var stmt in ifStmt.ElseBlock)
            CompileStatement(stmt, result);
    }

    private void CompileWhile(WhileStatement whileStmt, CompileResult result)
    {
        string loopStart = GenLabel();
        string loopEnd = GenLabel();

        enc.Mov(3, 0);
        enc.Je(whileStmt.Body.Count * 10);

        CompileCondition(whileStmt.Condition);
        int jneLoc = enc.Length;
        enc.Jne(0);

        foreach (var stmt in whileStmt.Body)
            CompileStatement(stmt, result);

        enc.Jmp((int)(labels[loopStart] - enc.Length - 5));

        PatchJump(jneLoc, enc.Length - jneLoc);
    }

    private void CompileReturn(ReturnStatement ret)
    {
        if (ret.Value != null)
        {
            CompileExpr(ret.Value);
        }
        enc.Ret();
    }

    private void CompileExpr(ASTNode expr)
    {
        switch (expr)
        {
            case BinaryExpr bin:
                CompileBinaryExpr(bin);
                break;
            case UnaryExpr unary:
                CompileUnaryExpr(unary);
                break;
            case CallExpr call:
                CompileCall(call);
                break;
            case VarRef varRef:
                CompileVarRef(varRef);
                break;
            case IntLiteral lit:
                enc.Mov(0, lit.Value);
                break;
            case FloatLiteral fl:
                enc.Mov(0, BitConverter.DoubleToInt64Bits(fl.Value));
                break;
        }
    }

    private void CompileBinaryExpr(BinaryExpr bin)
    {
        CompileExpr(bin.Left);
        enc.Push(0);

        CompileExpr(bin.Right);
        enc.Pop(1);

        switch (bin.Op)
        {
            case "+":
                enc.Add(0, 1);
                break;
            case "-":
                enc.Sub(0, 1);
                break;
            case "*":
                enc.Push(0);
                enc.Mov(0, 1);
                enc.Pop(1);
                enc.Imul(0, 1);
                break;
            case "/":
                enc.Push(0);
                enc.Mov(0, 1);
                enc.Pop(1);
                enc.Cqo();
                enc.Idiv(0);
                break;
            case "==":
                enc.Cmp(0, 1);
                enc.Xor(0, 0);
                enc.Setcc(0, 0x4);
                break;
            case "!=":
                enc.Cmp(0, 1);
                enc.Xor(0, 0);
                enc.Setcc(0, 0x5);
                break;
            case "<":
                enc.Cmp(0, 1);
                enc.Xor(0, 0);
                enc.Setcc(0, 0x2);
                break;
            case ">":
                enc.Cmp(1, 0);
                enc.Xor(0, 0);
                enc.Setcc(0, 0x7);
                break;
        }
    }

    private void CompileUnaryExpr(UnaryExpr unary)
    {
        CompileExpr(unary.Operand);
        switch (unary.Op)
        {
            case "-":
                enc.Neg(0);
                break;
            case "!":
                enc.Xor(0, 0);
                enc.Cmp(0, 1);
                break;
            case "~":
                enc.Not(0);
                break;
        }
    }

    private void CompileCall(CallExpr call)
    {
        int stackArgs = Math.Max(0, call.Args.Count - 4);
        if (stackArgs > 0)
        {
            enc.Sub(4, (byte)(stackArgs * 8));
        }

        int argIdx = 0;
        foreach (var arg in call.Args.Take(4))
        {
            CompileExpr(arg);
            int paramReg = argIdx < 4 ? new[] { 1, 2, 8, 9 }[argIdx] : 0;
            enc.Push((byte)paramReg);
            argIdx++;
        }

        if (call.Args.Count > 4)
        {
            foreach (var arg in call.Args.Skip(4))
            {
                CompileExpr(arg);
                enc.Push(0);
            }
        }

        if (symbols.TryGetValue(call.Name, out long addr))
        {
            enc.Call((int)(addr - enc.BaseAddress - enc.Length - 5));
        }
        else
        {
            enc.Call(0);
            jmpLocations.Add(enc.Length - 4);
        }

        if (stackArgs > 0)
        {
            enc.Add(4, (byte)(stackArgs * 8));
        }
    }

    private void CompileVarRef(VarRef varRef)
    {
        if (locals.TryGetValue(varRef.Name, out int offset))
        {
            enc.Mov(0, 8, (byte)(12));
            enc.Mov(0, offset - localOffset + 8, 0);
        }
    }

    private void CompileCondition(ASTNode cond)
    {
        CompileExpr(cond);
        enc.Cmp(0, 0);
    }

    private void CompileOnEvent(OnEventStatement on)
    {
        enc.Push(0);
        enc.Cmp(0, 0);
        enc.Jne(on.Handler.Count * 10);
        foreach (var stmt in on.Handler)
            CompileStatement(stmt, new CompileResult());
        enc.Pop(0);
    }

    private void CompileEnter(EnterStatement enter)
    {
        if (symbols.TryGetValue(enter.Target, out long addr))
        {
            enc.Call((int)(addr - enc.BaseAddress - enc.Length - 5));
        }
        else
        {
            enc.Call(0);
            jmpLocations.Add(enc.Length - 4);
        }
    }

    private string GeneratePrologue(int localsSize)
    {
        if (currentAbi == AbiType.Windows)
            return new WindowsX64Abi().GenPrologue(localsSize);
        return new SystemVX64Abi().GenPrologue(localsSize);
    }

    private string GenerateEpilogue(int localsSize)
    {
        if (currentAbi == AbiType.Windows)
            return new WindowsX64Abi().GenEpilogue(localsSize);
        return new SystemVX64Abi().GenEpilogue(localsSize);
    }

    private void EmitAsm(string asm)
    {
        foreach (var line in asm.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith(";") || string.IsNullOrEmpty(trimmed)) continue;

            if (trimmed == "push rbp") enc.Push(5);
            else if (trimmed == "mov rbp, rsp") enc.Mov(5, 4);
            else if (trimmed.StartsWith("sub rsp,"))
            {
                var parts = trimmed.Split(',');
                if (parts.Length > 1 && int.TryParse(parts[1].Trim(), out int val))
                    enc.Sub(4, (byte)val);
            }
            else if (trimmed == "pop rbp") enc.Pop(5);
            else if (trimmed == "ret") enc.Ret();
            else if (trimmed.StartsWith("push r"))
            {
                var regStr = trimmed.Substring(5);
                if (int.TryParse(regStr, out int r)) enc.Push((byte)r);
            }
            else if (trimmed.StartsWith("pop r"))
            {
                var regStr = trimmed.Substring(4);
                if (int.TryParse(regStr, out int r)) enc.Pop((byte)r);
            }
            else if (trimmed.StartsWith("add rsp,"))
            {
                var parts = trimmed.Split(',');
                if (parts.Length > 1 && int.TryParse(parts[1].Trim(), out int val))
                    enc.Add(4, (byte)val);
            }
        }
    }

    private void ApplyPatches(CompileResult result)
    {
        for (int i = 0; i < jmpLocations.Count && i < result.Symbols.Count; i++)
        {
        }
    }

    private void PatchJump(int location, int offset)
    {
    }

    private string GenLabel()
    {
        string label = $"L{labels.Count}";
        labels[label] = enc.Length;
        return label;
    }

    private long? EvalImmediate(ASTNode node)
    {
        if (node is IntLiteral lit) return lit.Value;
        return null;
    }

    private int EstimateLocalsSize(List<ASTNode> body)
    {
        int count = 0;
        foreach (var stmt in body)
        {
            if (stmt is VariableDecl) count++;
            else if (stmt is IfStatement ifs)
            {
                count += EstimateLocalsSize(ifs.ThenBlock);
                count += EstimateLocalsSize(ifs.ElseBlock);
            }
            else if (stmt is WhileStatement ws)
                count += EstimateLocalsSize(ws.Body);
        }
        return count * 8 + 8;
    }

    public string PrintCode(CompileResult result)
    {
        var sb = new StringBuilder();
        sb.AppendLine("; Compiled Machine Code");
        sb.AppendLine($"; Length: {result.Code.Length} bytes");
        sb.AppendLine($"; Instructions: {result.Instructions}");
        sb.AppendLine($"; Est cycles: {result.EstCycles:F1}");

        for (int i = 0; i < result.Code.Length; i += 16)
        {
            int len = Math.Min(16, result.Code.Length - i);
            var bytes = result.Code.Skip(i).Take(len).ToArray();
            sb.AppendLine($"{result.Symbols.GetValueOrDefault("main", 0) + i:X8}: {BitConverter.ToString(bytes)}");
        }

        return sb.ToString();
    }
}

public class ASTNode { }

public class FunctionDef : ASTNode
{
    public string Name { get; set; } = "";
    public List<ASTNode> Body { get; set; } = new();
}

public class VariableDecl : ASTNode
{
    public string Name { get; set; } = "";
    public ASTNode? Init { get; set; }
}

public class Assignment : ASTNode
{
    public string Target { get; set; } = "";
    public ASTNode Value { get; set; } = new();
}

public class IfStatement : ASTNode
{
    public ASTNode Condition { get; set; } = new();
    public List<ASTNode> ThenBlock { get; set; } = new();
    public List<ASTNode> ElseBlock { get; set; } = new();
}

public class WhileStatement : ASTNode
{
    public ASTNode Condition { get; set; } = new();
    public List<ASTNode> Body { get; set; } = new();
}

public class ReturnStatement : ASTNode
{
    public ASTNode? Value { get; set; }
}

public class ExprStatement : ASTNode
{
    public ASTNode Expr { get; set; } = new();
}

public class OnEventStatement : ASTNode
{
    public string Event { get; set; } = "";
    public List<ASTNode> Handler { get; set; } = new();
}

public class EnterStatement : ASTNode
{
    public string Target { get; set; } = "";
}

public class BinaryExpr : ASTNode
{
    public string Op { get; set; } = "";
    public ASTNode Left { get; set; } = new();
    public ASTNode Right { get; set; } = new();
}

public class UnaryExpr : ASTNode
{
    public string Op { get; set; } = "";
    public ASTNode Operand { get; set; } = new();
}

public class CallExpr : ASTNode
{
    public string Name { get; set; } = "";
    public List<ASTNode> Args { get; set; } = new();
}

public class VarRef : ASTNode
{
    public string Name { get; set; } = "";
}

public class IntLiteral : ASTNode
{
    public long Value { get; set; }
}

public class FloatLiteral : ASTNode
{
    public double Value { get; set; }
}

public class BranchLayoutOptimizer
{
    public class LayoutResult
    {
        public List<ASTNode> OptimizedBody { get; set; } = new();
        public int EstJumpsSaved { get; set; }
    }

    public LayoutResult Optimize(List<ASTNode> body)
    {
        var result = new LayoutResult { OptimizedBody = body };
        return result;
    }

    public string Analyze(List<ASTNode> body)
    {
        int branches = 0, jumps = 0;
        foreach (var node in body)
        {
            if (node is IfStatement) branches++;
            else if (node is WhileStatement) jumps++;
        }
        return $"Branches: {branches}, Jumps: {jumps}";
    }
}

public class GuardConditionOptimizer
{
    public class GuardInfo
    {
        public string Condition { get; set; } = "";
        public bool Likely { get; set; }
        public int EstSpeedup { get; set; }
    }

    public GuardInfo Analyze(ASTNode condition)
    {
        var info = new GuardInfo();
        if (condition is BinaryExpr bin)
        {
            info.Condition = bin.Op;
            if (bin.Op == "==" || bin.Op == "!=")
                info.Likely = true;
        }
        return info;
    }

    public string EmitHint(GuardInfo info)
    {
        return info.Likely ? "__builtin_expect(1)" : "__builtin_expect(0)";
    }
}

public class JumpTableGenerator
{
    public class JumpTableInfo
    {
        public string TableName { get; set; } = "";
        public List<int> Targets { get; set; } = new();
        public byte[] TableData { get; set; } = Array.Empty<byte>();
    }

    public JumpTableInfo Generate(List<int> cases, int defaultTarget)
    {
        var info = new JumpTableInfo
        {
            TableName = $"jump_table_{cases.Count}",
            Targets = new List<int>(cases)
        };

        var data = new List<byte>();
        foreach (var t in cases)
        {
            data.AddRange(BitConverter.GetBytes(t));
        }
        info.TableData = data.ToArray();

        return info;
    }

    public string EmitAsm(JumpTableInfo info)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"section .rodata");
        sb.AppendLine($"{info.TableName}:");
        foreach (var t in info.Targets)
            sb.AppendLine($"  dq {t}");
        return sb.ToString();
    }
}
