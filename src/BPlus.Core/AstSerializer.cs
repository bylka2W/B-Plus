using System.Text;
using System.Text.Json;
using BPlus.Core.Ast;
using BPlus.Core.Parser;

namespace BPlus.Core;

public static class AstSerializer
{
    public static string Serialize(ProgramNode program)
    {
        using var stream = new MemoryStream();
        using var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = false });
        
        writer.WriteStartObject();
        
        // Entry
        if (program.Entries.Count > 0)
        {
            var entry = program.Entries[0];
            writer.WriteStartObject("entry");
            writer.WriteString("name", entry.Name);
            var bodyText = entry.Body ?? string.Join("\n", entry.BodyLines);
            writer.WriteString("body", bodyText);
            writer.WritePropertyName("body_stmts");
            BodyJsonParser.SerializeBodyStatements(writer, bodyText);
            writer.WriteEndObject();
        }

        // Context variables (global to all states)
        if (program.Context?.Variables.Count > 0)
        {
            writer.WriteStartArray("vars");
            foreach (var v in program.Context.Variables)
            {
                writer.WriteStartObject();
                writer.WriteString("name", v.Name);
                writer.WriteString("type", v.Type);
                if (v.DefaultValue != null)
                {
                    writer.WriteString("init", v.DefaultValue);
                    if (int.TryParse(v.DefaultValue, out _))
                        writer.WriteString("init_type", "int");
                    else if (double.TryParse(v.DefaultValue, out _))
                        writer.WriteString("init_type", "float");
                    else if (v.DefaultValue is "true" or "false")
                        writer.WriteString("init_type", "bool");
                    else
                        writer.WriteString("init_type", "string");
                }
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
        }

        // First state name (entry point if no entry main)
        if (program.Entries.Count == 0 && program.States.Count > 0)
        {
            writer.WriteString("start_state", program.States[0].Name);
        }
        
        // States
        writer.WriteStartArray("states");
        foreach (var state in program.States)
        {
            writer.WriteStartObject();
            writer.WriteString("name", state.Name);
            
            // Vars
            if (state.Variables.Count > 0)
            {
                writer.WriteStartArray("vars");
                foreach (var v in state.Variables)
                {
                    writer.WriteStartObject();
                    writer.WriteString("name", v.Name);
                    writer.WriteString("type", v.Type);
                    if (v.DefaultValue != null)
                    {
                        writer.WriteString("init", v.DefaultValue);
                        // Try to detect literal type
                        if (int.TryParse(v.DefaultValue, out _))
                            writer.WriteString("init_type", "int");
                        else if (double.TryParse(v.DefaultValue, out _))
                            writer.WriteString("init_type", "float");
                        else if (v.DefaultValue is "true" or "false")
                            writer.WriteString("init_type", "bool");
                        else
                            writer.WriteString("init_type", "string");
                    }
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
            }
            
            // Actions (enter / exit blocks)
            if (state.Actions.Count > 0)
            {
                writer.WriteStartArray("actions");
                foreach (var a in state.Actions)
                {
                    writer.WriteStartObject();
                    writer.WriteString("type", a.Type == ActionType.Enter ? "enter" : "exit");
                    if (!string.IsNullOrEmpty(a.Body))
                    {
                        writer.WriteString("body", a.Body);
                        writer.WritePropertyName("body_stmts");
                        BodyJsonParser.SerializeBodyStatements(writer, a.Body);
                    }
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
            }

            // Transitions
            if (state.Transitions.Count > 0)
            {
                writer.WriteStartArray("transitions");
                foreach (var t in state.Transitions)
                {
                    writer.WriteStartObject();
                    writer.WriteString("event", t.EventName);
                    writer.WriteString("target", t.Target);
                    if (!string.IsNullOrEmpty(t.Guard))
                    {
                        writer.WriteString("guard", t.Guard);
                        writer.WritePropertyName("guard_stmts");
                        BodyJsonParser.SerializeBodyStatements(writer, t.Guard);
                    }
                    if (!string.IsNullOrEmpty(t.Body))
                    {
                        writer.WriteString("body", t.Body);
                        writer.WritePropertyName("body_stmts");
                        BodyJsonParser.SerializeBodyStatements(writer, t.Body);
                    }
                    if (t.HotWeight.HasValue)
                        writer.WriteNumber("hot", t.HotWeight.Value);
                    writer.WriteBoolean("is_always", t.IsAlways);
                    writer.WriteBoolean("is_enter", t.IsEnterAuto);
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
            }
            
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
        
        writer.WriteEndObject();
        writer.Flush();
        
        return Encoding.UTF8.GetString(stream.ToArray());
    }
}
