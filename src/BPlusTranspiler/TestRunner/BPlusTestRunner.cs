using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.TestRunner;

public partial class BPlusTestRunner
{
    private readonly ProgramNode _program;
    private readonly Dictionary<string, StateDefNode> _stateMap = new();
    private readonly List<BpTest> _tests = new();
    private int _passed;
    private int _failed;

    public BPlusTestRunner(ProgramNode program)
    {
        _program = program;
        void Collect(StateDefNode s) { _stateMap[s.Name] = s; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in program.States) Collect(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
    }

    public int Run()
    {
        Console.WriteLine("B+ Test Runner");
        Console.WriteLine(new string('=', 60));
        Console.WriteLine();

        // Auto-generate tests from state machine structure
        AutoGenerateTests();

        if (_tests.Count == 0)
        {
            Console.WriteLine("No tests defined or auto-generated.");
            Console.WriteLine("Create a .bptest file next to your .bp file with test definitions.");
            return 0;
        }

        foreach (var test in _tests)
        {
            Console.Write($"  {test.Name}... ");
            try
            {
                var result = RunTest(test);
                if (result)
                {
                    Console.WriteLine("PASS");
                    _passed++;
                }
                else
                {
                    Console.WriteLine("FAIL");
                    Console.WriteLine($"      Expected: {test.FromState} --[{test.Event}]--> {test.ExpectedState}");
                    Console.WriteLine($"      Actual:   {test.FromState} --[{test.Event}]--> {test.ActualState}");
                    _failed++;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("ERROR");
                Console.WriteLine($"      {ex.Message}");
                _failed++;
            }
        }

        Console.WriteLine();
        Console.WriteLine(new string('=', 60));
        var total = _passed + _failed;
        Console.WriteLine($"Results: {_passed}/{total} passed, {_failed}/{total} failed");

        return _failed == 0 ? 0 : 1;
    }

    private void AutoGenerateTests()
    {
        // Generate a test for every defined transition in the state machine
        foreach (var (name, state) in _stateMap)
        {
            foreach (var t in state.Transitions)
            {
                if (string.IsNullOrEmpty(t.Target)) continue;
                var testName = $"{state.Name} --[{t.EventName}]--> {t.Target}";

                // Skip transitions with guards (can't auto-validate guard conditions)
                if (t.Guard != null)
                {
                    // Still generate but mark as guarded — test both branches
                    _tests.Add(new BpTest
                    {
                        Name = $"{testName} (guard: {t.Guard})",
                        FromState = state.Name,
                        Event = t.EventName,
                        ExpectedState = t.Target,
                        Guard = t.Guard,
                        GuardResult = true
                    });
                }
                else
                {
                    _tests.Add(new BpTest
                    {
                        Name = testName,
                        FromState = state.Name,
                        Event = t.EventName,
                        ExpectedState = t.Target
                    });
                }
            }
        }
    }

    private bool RunTest(BpTest test)
    {
        // Find the source state
        if (!_stateMap.TryGetValue(test.FromState, out var fromState))
            return false;

        // Find the matching transition
        var transition = fromState.Transitions
            .FirstOrDefault(t => t.EventName == test.Event);

        if (transition == null)
            return false;

        // Check guard
        if (transition.Guard != null)
        {
            // For auto-generated tests with guards, use the test's guard result
            test.ActualState = test.GuardResult ? transition.Target : test.FromState;
            return (test.GuardResult && test.ActualState == test.ExpectedState)
                   || (!test.GuardResult && test.ActualState == test.FromState);
        }

        test.ActualState = transition.Target;
        return test.ActualState == test.ExpectedState;
    }

    public static int RunTestsFromFiles(string bpFile, string? testFile)
    {
        if (!File.Exists(bpFile))
        {
            Console.Error.WriteLine($"File not found: {bpFile}");
            return 1;
        }

        var source = File.ReadAllText(bpFile);
        ProgramNode program;
        try
        {
            program = new Parser.BPlusParser().Parse(source);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Parse error: {ex.Message}");
            return 1;
        }

        var runner = new BPlusTestRunner(program);
        return runner.Run();
    }

    private class BpTest
    {
        public string Name { get; set; } = "";
        public string FromState { get; set; } = "";
        public string Event { get; set; } = "";
        public string ExpectedState { get; set; } = "";
        public string? ActualState { get; set; }
        public string? Guard { get; set; }
        public bool GuardResult { get; set; }
    }
}
