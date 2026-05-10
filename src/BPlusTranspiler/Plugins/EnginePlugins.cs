using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;

namespace BPlusTranspiler.Plugins;

public class UnityPlugin : ICodeGenerator
{
    public string GetFileExtension() => ".cs";
    public string GetLanguageName() => "Unity (C#)";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("using UnityEngine;");
        sb.AppendLine("using System.Collections.Generic;");
        sb.AppendLine();

        var name = program.States.FirstOrDefault()?.Name ?? "StateMachine";
        sb.AppendLine($"public class {name}FSM : MonoBehaviour");
        sb.AppendLine("{");

        // State enum
        sb.AppendLine("    public enum State");
        sb.AppendLine("    {");
        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in program.States) Collect(s);
        foreach (var s in allStates)
            sb.AppendLine($"        {s.Name},");
        sb.AppendLine("    }");
        sb.AppendLine();

        // Current state
        sb.AppendLine("    public State currentState = State." + (program.States.FirstOrDefault()?.Name ?? "Idle") + ";");
        sb.AppendLine();

        // Variables
        foreach (var s in allStates)
            foreach (var v in s.Variables)
                sb.AppendLine($"    public {v.Type} {s.Name}_{v.Name} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
        if (allStates.Any(s => s.Variables.Count > 0)) sb.AppendLine();

        // Start/Update
        sb.AppendLine("    void Start()");
        sb.AppendLine("    {");
        sb.AppendLine("        OnStateEnter(currentState);");
        sb.AppendLine("    }");
        sb.AppendLine();
        sb.AppendLine("    void Update()");
        sb.AppendLine("    {");
        sb.AppendLine("        Tick(currentState);");
        sb.AppendLine("    }");
        sb.AppendLine();

        // Enter/exit helpers
        sb.AppendLine("    void OnStateEnter(State state)");
        sb.AppendLine("    {");
        sb.AppendLine("        switch (state) {");
        foreach (var s in allStates.Where(s => s.Actions.Any(a => a.Type == ActionType.Enter)))
            sb.AppendLine($"            case State.{s.Name}: {s.Actions.First(a => a.Type == ActionType.Enter).Body}; break;");
        sb.AppendLine("        }");
        sb.AppendLine("    }");
        sb.AppendLine();

        sb.AppendLine("    void OnStateExit(State state)");
        sb.AppendLine("    {");
        sb.AppendLine("        switch (state) {");
        foreach (var s in allStates.Where(s => s.Actions.Any(a => a.Type == ActionType.Exit)))
            sb.AppendLine($"            case State.{s.Name}: {s.Actions.First(a => a.Type == ActionType.Exit).Body}; break;");
        sb.AppendLine("        }");
        sb.AppendLine("    }");
        sb.AppendLine();

        // Transition method
        sb.AppendLine("    public void Transition(State target)");
        sb.AppendLine("    {");
        sb.AppendLine("        OnStateExit(currentState);");
        sb.AppendLine("        currentState = target;");
        sb.AppendLine("        OnStateEnter(currentState);");
        sb.AppendLine("    }");
        sb.AppendLine();

        // Fire event
        sb.AppendLine("    public void Fire(string eventName)");
        sb.AppendLine("    {");
        sb.AppendLine("        switch (currentState)");
        sb.AppendLine("        {");
        foreach (var s in allStates)
        {
            if (s.Transitions.Count == 0) continue;
            sb.AppendLine($"            case State.{s.Name}:");
            var i = 0;
            foreach (var t in s.Transitions)
            {
                var c = i > 0 ? "else if" : "if";
                if (t.Guard != null)
                    sb.AppendLine($"                {c} (eventName == \"{t.EventName}\" && {t.Guard}) {{ if (!string.IsNullOrEmpty(\"{t.Body}\")) {{ /* {t.Body} */ }} Transition(State.{t.Target}); }}");
                else
                    sb.AppendLine($"                {c} (eventName == \"{t.EventName}\") {{ if (!string.IsNullOrEmpty(\"{t.Body}\")) {{ /* {t.Body} */ }} Transition(State.{t.Target}); }}");
                i++;
            }
            sb.AppendLine($"                break;");
        }
        sb.AppendLine("        }");
        sb.AppendLine("    }");
        sb.AppendLine();

        // Tick (for timer transitions)
        sb.AppendLine("    void Tick(State state)");
        sb.AppendLine("    {");
        sb.AppendLine("        switch (state)");
        sb.AppendLine("        {");
        foreach (var s in allStates.Where(s => s.Timers.Count > 0))
        {
            sb.AppendLine($"            case State.{s.Name}:");
            foreach (var t in s.Timers)
                sb.AppendLine($"                /* timer: after {t.Duration} -> {t.Target} */");
            sb.AppendLine($"                break;");
        }
        sb.AppendLine("        }");
        sb.AppendLine("    }");
        sb.AppendLine("}");

        return new Dictionary<string, string> { { "StateMachine.cs", sb.ToString() } };
    }

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "long" or "float" or "double" => "0",
        "bool" => "false",
        "string" => "\"\"",
        _ => "null"
    };
}

public class UnrealPlugin : ICodeGenerator
{
    public string GetFileExtension() => ".h";
    public string GetLanguageName() => "Unreal (C++)";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include \"CoreMinimal.h\"");
        sb.AppendLine("#include \"GameFramework/Actor.h\"");
        sb.AppendLine($"#include \"{(program.States.FirstOrDefault()?.Name ?? "StateMachine")}FSM.generated.h\"");
        sb.AppendLine();

        var name = program.States.FirstOrDefault()?.Name ?? "StateMachine";
        sb.AppendLine($"UCLASS()");
        sb.AppendLine($"class A{name}FSM : public AActor");
        sb.AppendLine("{");
        sb.AppendLine("    GENERATED_BODY()");
        sb.AppendLine();

        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in program.States) Collect(s);

        sb.AppendLine("public:");
        sb.AppendLine($"    enum class State : uint8 {{");
        foreach (var s in allStates)
            sb.AppendLine($"        {s.Name},");
        sb.AppendLine($"        COUNT");
        sb.AppendLine("    };");
        sb.AppendLine();

        sb.AppendLine($"    State CurrentState = State::{allStates.FirstOrDefault()?.Name ?? "Idle"};");
        sb.AppendLine();

        sb.AppendLine("    UFUNCTION()");
        sb.AppendLine("    void OnStateEnter(State NewState);");
        sb.AppendLine("    UFUNCTION()");
        sb.AppendLine("    void OnStateExit(State OldState);");
        sb.AppendLine("    UFUNCTION()");
        sb.AppendLine("    void FireEvent(const FString& EventName);");
        sb.AppendLine();

        sb.AppendLine("    virtual void BeginPlay() override;");
        sb.AppendLine("    virtual void Tick(float DeltaTime) override;");
        sb.AppendLine("};");

        // Implementation
        var impl = new StringBuilder();
        impl.AppendLine($"#include \"{name}FSM.h\"");
        impl.AppendLine();
        impl.AppendLine($"void A{name}FSM::BeginPlay() {{ Super::BeginPlay(); OnStateEnter(CurrentState); }}");
        impl.AppendLine($"void A{name}FSM::Tick(float DeltaTime) {{ Super::Tick(DeltaTime); }}");
        impl.AppendLine();

        impl.AppendLine($"void A{name}FSM::OnStateEnter(State NewState)");
        impl.AppendLine("{");
        impl.AppendLine("    switch (NewState) {");
        foreach (var s in allStates.Where(s => s.Actions.Any(a => a.Type == ActionType.Enter)))
            impl.AppendLine($"        case State::{s.Name}: {s.Actions.First(a => a.Type == ActionType.Enter).Body}; break;");
        impl.AppendLine("        default: break;");
        impl.AppendLine("    }");
        impl.AppendLine("}");
        impl.AppendLine();

        impl.AppendLine($"void A{name}FSM::OnStateExit(State OldState)");
        impl.AppendLine("{");
        impl.AppendLine("    switch (OldState) {");
        foreach (var s in allStates.Where(s => s.Actions.Any(a => a.Type == ActionType.Exit)))
            impl.AppendLine($"        case State::{s.Name}: {s.Actions.First(a => a.Type == ActionType.Exit).Body}; break;");
        impl.AppendLine("        default: break;");
        impl.AppendLine("    }");
        impl.AppendLine("}");
        impl.AppendLine();

        impl.AppendLine($"void A{name}FSM::FireEvent(const FString& EventName)");
        impl.AppendLine("{");
        impl.AppendLine("    switch (CurrentState) {");
        foreach (var s in allStates)
        {
            if (s.Transitions.Count == 0) continue;
            impl.AppendLine($"        case State::{s.Name}: {{");
            foreach (var t in s.Transitions)
            {
                impl.AppendLine($"            if (EventName == \"{t.EventName}\") {{");
                impl.AppendLine($"                OnStateExit(CurrentState);");
                impl.AppendLine($"                CurrentState = State::{t.Target};");
                impl.AppendLine($"                OnStateEnter(CurrentState);");
                impl.AppendLine($"                return;");
                impl.AppendLine($"            }}");
            }
            impl.AppendLine($"            break;");
            impl.AppendLine($"        }}");
        }
        impl.AppendLine("        default: break;");
        impl.AppendLine("    }");
        impl.AppendLine("}");

        return new Dictionary<string, string>
        {
            { $"{name}FSM.h", sb.ToString() },
            { $"{name}FSM.cpp", impl.ToString() }
        };
    }
}

public class GodotPlugin : ICodeGenerator
{
    public string GetFileExtension() => ".cs";
    public string GetLanguageName() => "Godot (C#)";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("using Godot;");
        sb.AppendLine("using System.Collections.Generic;");
        sb.AppendLine();

        var name = program.States.FirstOrDefault()?.Name ?? "StateMachine";
        sb.AppendLine($"public partial class {name}FSM : Node");
        sb.AppendLine("{");

        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in program.States) Collect(s);

        sb.AppendLine("    public enum State");
        sb.AppendLine("    {");
        foreach (var s in allStates)
            sb.AppendLine($"        {s.Name},");
        sb.AppendLine("    }");
        sb.AppendLine();

        sb.AppendLine($"    public State currentState = State.{allStates.FirstOrDefault()?.Name ?? "Idle"};");
        sb.AppendLine();

        sb.AppendLine("    public override void _Ready()");
        sb.AppendLine("    {");
        sb.AppendLine("        OnEnter(currentState);");
        sb.AppendLine("    }");
        sb.AppendLine();

        sb.AppendLine("    void OnEnter(State state)");
        sb.AppendLine("    {");
        sb.AppendLine("        switch (state) {");
        foreach (var s in allStates.Where(s => s.Actions.Any(a => a.Type == ActionType.Enter)))
            sb.AppendLine($"            case State.{s.Name}: {s.Actions.First(a => a.Type == ActionType.Enter).Body}; break;");
        sb.AppendLine("        }");
        sb.AppendLine("    }");
        sb.AppendLine();

        sb.AppendLine("    void OnExit(State state)");
        sb.AppendLine("    {");
        sb.AppendLine("        switch (state) {");
        foreach (var s in allStates.Where(s => s.Actions.Any(a => a.Type == ActionType.Exit)))
            sb.AppendLine($"            case State.{s.Name}: {s.Actions.First(a => a.Type == ActionType.Exit).Body}; break;");
        sb.AppendLine("        }");
        sb.AppendLine("    }");
        sb.AppendLine();

        sb.AppendLine("    public void Fire(string eventName)");
        sb.AppendLine("    {");
        sb.AppendLine("        switch (currentState)");
        sb.AppendLine("        {");
        foreach (var s in allStates)
        {
            if (s.Transitions.Count == 0) continue;
            sb.AppendLine($"            case State.{s.Name}:");
            foreach (var t in s.Transitions)
            {
                var guard = t.Guard != null ? $" && {t.Guard}" : "";
                sb.AppendLine($"                if (eventName == \"{t.EventName}\"{guard}) {{ OnExit(currentState); currentState = State.{t.Target}; OnEnter(currentState); }}");
            }
            sb.AppendLine($"                break;");
        }
        sb.AppendLine("        }");
        sb.AppendLine("    }");
        sb.AppendLine("}");

        return new Dictionary<string, string> { { $"{name}FSM.cs", sb.ToString() } };
    }
}

public class WebPlugin : ICodeGenerator
{
    public string GetFileExtension() => ".ts";
    public string GetLanguageName() => "Web (TS)";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var sb = new StringBuilder();

        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in program.States) Collect(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);

        // State enum
        sb.AppendLine("export enum State {");
        foreach (var s in allStates)
            sb.AppendLine($"  {s.Name} = '{s.Name}',");
        sb.AppendLine("}");

        // Context interface
        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine();
            sb.AppendLine("export interface Context {");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"  {v.Name}: {MapTsType(v.Type)};");
            sb.AppendLine("}");
        }
        sb.AppendLine();

        // State machine class
        var name = program.States.FirstOrDefault()?.Name ?? "StateMachine";
        sb.AppendLine($"export class {name}FSM {{");

        // Constructor
        sb.AppendLine($"  currentState: State = State.{allStates.FirstOrDefault()?.Name ?? "Idle"};");
        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("  context: Context = {");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"    {v.Name}: {v.DefaultValue ?? TsDefault(v.Type)},");
            sb.AppendLine("  };");
        }
        sb.AppendLine();
        sb.AppendLine("  private enterHandlers: Record<State, (() => void) | null> = {");
        foreach (var s in allStates)
        {
            var enter = s.Actions.FirstOrDefault(a => a.Type == ActionType.Enter);
            sb.AppendLine($"    State.{s.Name}: {(enter != null ? $"() => {{ {enter.Body} }}" : "null")},");
        }
        sb.AppendLine("  };");
        sb.AppendLine();
        sb.AppendLine("  private exitHandlers: Record<State, (() => void) | null> = {");
        foreach (var s in allStates)
        {
            var exit = s.Actions.FirstOrDefault(a => a.Type == ActionType.Exit);
            sb.AppendLine($"    State.{s.Name}: {(exit != null ? $"() => {{ {exit.Body} }}" : "null")},");
        }
        sb.AppendLine("  };");
        sb.AppendLine();

        // Fire method
        sb.AppendLine("  fire(eventName: string): void {");
        sb.AppendLine("    switch (this.currentState) {");
        foreach (var s in allStates)
        {
            if (s.Transitions.Count == 0) continue;
            sb.AppendLine($"      case State.{s.Name}:");
            foreach (var t in s.Transitions)
            {
                var guard = t.Guard != null ? $" && {t.Guard}" : "";
                sb.AppendLine($"        if (eventName === '{t.EventName}'{guard}) {{");
                sb.AppendLine($"          this.exitHandlers[this.currentState]?.();");
                sb.AppendLine($"          this.currentState = State.{t.Target};");
                sb.AppendLine($"          this.enterHandlers[this.currentState]?.();");
                sb.AppendLine($"          return;");
                sb.AppendLine($"        }}");
            }
            sb.AppendLine($"        break;");
        }
        sb.AppendLine("    }");
        sb.AppendLine("  }");
        sb.AppendLine("}");

        return new Dictionary<string, string> { { $"{name}FSM.ts", sb.ToString() } };
    }

    private static string MapTsType(string type) => type.ToLower() switch
    {
        "int" or "long" or "float" or "double" or "number" => "number",
        "bool" => "boolean",
        "string" => "string",
        "void" => "void",
        _ => "any"
    };

    private static string TsDefault(string type) => type.ToLower() switch
    {
        "int" or "long" or "float" or "double" => "0",
        "bool" => "false",
        "string" => "''",
        _ => "undefined"
    };
}
