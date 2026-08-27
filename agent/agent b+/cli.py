import sys
import os
import time
import json
import torch
from pathlib import Path

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_BPLUS = os.path.dirname(os.path.abspath(__file__))

sys.path.insert(0, AGENT_BPLUS)
sys.path.insert(0, AGENT_DIR)

BANNER = r"""
============================================================
  B+ AGENT  v0.3.0
  Zig-Optimized Autonomous Coding Agent
  Knowledge + Source + Graph + Verification
============================================================
"""

HELP_TEXT = """
  COMMANDS:
    /status           System status
    /tools            List available tools
    /tool <name>      Tool details
    /knowledge <q>    Search knowledge base
    /source <q>       Search source files
    /relations <sym>  Get relations for symbol
    /evidence <q>     Get evidence for symbol
    /inspect <sym>    Deep symbol inspection
    /trace            Last execution trace
    /trace <id>       Specific trace
    /plan             Last execution plan
    /session          Session info
    /context          Active context
    /graph            Symbol graph stats
    /web              Knowledge web + coverage (/kcs,/coverage)
    /conversation     Conversation history
    /state            Persistent state stats
    /clear            Clear screen
    /reset            Reset conversation
    /help             Show this help
    /exit             Exit B+ Agent
"""


class AgentCLI:
    def __init__(self):
        self.agent = None

    def boot(self):
        print(BANNER)
        print("  Booting systems...")
        print()

        try:
            from knowledge.tokenizer import ZigTokenizer
            from core.model import build_model

            tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
            tokenizer = ZigTokenizer.load(tok_path)
            vocab_size = tokenizer.vocab_size()
            print(f"  [1/5] Tokenizer... OK (vocab={vocab_size})")

            ext_ckpt = Path(AGENT_BPLUS) / "checkpoints" / "model_extended.pt"
            model = build_model(vocab_size=vocab_size)
            if ext_ckpt.exists():
                ckpt = torch.load(ext_ckpt, map_location="cpu", weights_only=True)
                state_dict = {k: v for k, v in ckpt.items() if k != "optimizer_state"}
                model.load_state_dict(state_dict, strict=False)
            device = "cuda" if torch.cuda.is_available() else "cpu"
            model = model.to(device).eval()
            params = sum(p.nelement() for p in model.parameters())
            print(f"  [2/5] Model... OK ({params/1e6:.1f}M, {device})")

            from core.agent_runtime import KnowledgeQuery, SourceIndex, ZigRunner

            kb_dir = Path(AGENT_DIR) / "memory"
            knowledge = KnowledgeQuery(str(kb_dir))
            print(f"  [3/5] Knowledge... OK ({len(knowledge.facts)} facts, {len(knowledge.concepts)} concepts)")

            roots = [str(Path(r)) for r in [r"C:\B-Plus\zig", r"C:\Users\Local\zig"] if Path(r).exists()]
            source_index = SourceIndex(roots)
            source_index.scan()
            print(f"  [4/5] Source... OK ({len(source_index.files)} files)")

            zig_runner = ZigRunner()
            print(f"  [5/5] Zig... OK")

            from core.agent_runtime_v2 import AgentRuntimeV2
            self.agent = AgentRuntimeV2(model, tokenizer, knowledge, source_index, zig_runner)
            print()
            print("  ALL SYSTEMS READY")
            print()

        except Exception as e:
            print(f"  BOOT FAILED: {e}")
            import traceback
            traceback.print_exc()

    def handle_command(self, cmd: str):
        cmd = cmd.strip()
        if not cmd:
            return None

        handlers = {
            "/status": lambda: self._cmd_status(),
            "/tools": lambda: self._cmd_tools(),
            "/graph": lambda: self._cmd_graph(),
            "/web": lambda: self._cmd_web(),
            "/kcs": lambda: self._cmd_web(),
            "/coverage": lambda: self._cmd_web(),
            "/trace": lambda: self._cmd_trace(cmd),
            "/plan": lambda: self._cmd_plan(),
            "/session": lambda: self._cmd_session(),
            "/context": lambda: self._cmd_context(),
            "/conversation": lambda: self._cmd_conversation(),
            "/state": lambda: self._cmd_state(),
            "/clear": lambda: self._cmd_clear(),
            "/reset": lambda: self._cmd_reset(),
            "/help": lambda: self._cmd_help(),
        }

        for prefix, handler in handlers.items():
            if cmd == prefix:
                return handler()

        if cmd.startswith("/tool "):
            return self._cmd_tool_detail(cmd[6:].strip())
        if cmd.startswith("/knowledge "):
            return self._cmd_knowledge(cmd[11:].strip())
        if cmd.startswith("/source "):
            return self._cmd_source(cmd[8:].strip())
        if cmd.startswith("/relations "):
            return self._cmd_relations(cmd[11:].strip())
        if cmd.startswith("/evidence "):
            return self._cmd_evidence(cmd[10:].strip())
        if cmd.startswith("/inspect "):
            return self._cmd_inspect(cmd[9:].strip())
        if cmd in ("/exit", "/quit", "/q"):
            return "EXIT"

        return self._cmd_ask(cmd)

    def _cmd_status(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        stats = self.agent.get_conversation_stats()
        state_stats = self.agent.get_state_stats()
        tools = self.agent.get_tools()
        graph_stats = self.agent.get_symbol_graph_stats()
        lines = [
            "  B+ AGENT STATUS",
            "  " + "=" * 55,
            f"  Model:      READY ({sum(p.nelement() for p in self.agent.model.parameters())/1e6:.1f}M)",
            f"  Device:     {next(self.agent.model.parameters()).device}",
            f"  Knowledge:  {len(self.agent.knowledge.facts)} facts, {len(self.agent.knowledge.concepts)} concepts",
            f"  Source:     {len(self.agent.source_index.files)} files indexed",
            f"  Tools:      {len(tools)} registered",
            f"  Graph:      {graph_stats['symbols']} symbols, {graph_stats['relations']} relations",
            f"  Session:    {state_stats['sessions']} sessions, {state_stats['turns']} turns",
            f"  Plans:      {state_stats['plans']}",
            f"  Executions: {state_stats['executions']}",
            f"  Evidence:   {state_stats['evidence']}",
            f"  Traces:     {state_stats['traces']}",
            "  " + "=" * 55,
        ]
        return "\n".join(lines)

    def _cmd_tools(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        tools = self.agent.get_tools()
        lines = ["  REGISTERED TOOLS", "  " + "-" * 55]
        by_cat = {}
        for t in tools:
            cat = t["category"]
            if cat not in by_cat:
                by_cat[cat] = []
            by_cat[cat].append(t)
        for cat, cat_tools in sorted(by_cat.items()):
            lines.append(f"  [{cat.upper()}]")
            for t in cat_tools:
                risk = t["risk"]
                cost = t["cost_ms"]
                mut = "MUTATES" if t["mutates_source"] else "read-only"
                lines.append(f"    {t['name']:30s} [{risk:9s}] {cost:5d}ms {mut}")
                lines.append(f"      {t['description']}")
            lines.append("")
        return "\n".join(lines)

    def _cmd_tool_detail(self, name: str) -> str:
        if not self.agent:
            return "Agent not initialized."
        tool = self.agent.engine.get(name)
        if not tool:
            return f"  Tool not found: {name}"
        spec = tool.spec
        lines = [
            f"  TOOL: {spec.name}",
            "  " + "-" * 55,
            f"  Category:     {spec.category.value}",
            f"  Risk:         {spec.risk_level.value}",
            f"  Description:  {spec.description}",
            f"  Cost:         {spec.cost_ms}ms",
            f"  Timeout:      {spec.timeout_ms}ms",
            f"  Deterministic:{spec.deterministic}",
            f"  Mutates:      {spec.mutates_source}",
            f"  Requires ev:  {spec.requires_evidence}",
            f"  Permissions:  {spec.permissions}",
            f"  Input schema: {spec.input_schema}",
            f"  Output schema:{spec.output_schema}",
        ]
        return "\n".join(lines)

    def _cmd_knowledge(self, query: str) -> str:
        if not self.agent:
            return "Agent not initialized."
        if not query:
            return "Usage: /knowledge <query>"
        r = self.agent.engine.execute("knowledge.search", query=query)
        if not r.success:
            return f"Error: {r.error}"
        lines = [f"  KNOWLEDGE: {query}", "  " + "-" * 55]
        for item in r.data[:20]:
            t = item.get("type", "")
            pred = item.get("predicate", item.get("name", ""))
            subj = item.get("subject", item.get("name", ""))
            obj = item.get("object", item.get("description", ""))
            sf = item.get("source_file", "")
            if sf:
                sf = sf.split("\\")[-1]
            lines.append(f"  [{t}] {pred} {subj} {obj}")
            if sf:
                lines.append(f"         file: {sf}")
        if not r.data:
            lines.append("  No results found.")
        return "\n".join(lines)

    def _cmd_source(self, query: str) -> str:
        if not self.agent:
            return "Agent not initialized."
        if not query:
            return "Usage: /source <query>"
        r = self.agent.engine.execute("source.search", query=query)
        if not r.success:
            return f"Error: {r.error}"
        lines = [f"  SOURCE: {query}", "  " + "-" * 55]
        for item in r.data[:15]:
            path = item.get("path", "")
            score = item.get("score", 0)
            if path:
                path = path.split("\\")[-1]
            lines.append(f"  {path:40s} (score={score})")
        if not r.data:
            lines.append("  No results found.")
        return "\n".join(lines)

    def _cmd_relations(self, symbol: str) -> str:
        if not self.agent:
            return "Agent not initialized."
        if not symbol:
            return "Usage: /relations <symbol>"
        r = self.agent.engine.execute("knowledge.relations", symbol=symbol)
        if not r.success:
            return f"Error: {r.error}"
        lines = [f"  RELATIONS: {symbol}", "  " + "-" * 55]
        for item in r.data[:20]:
            lines.append(f"  {json.dumps(item, ensure_ascii=False)[:200]}")
        if not r.data:
            lines.append("  No relations found.")
        return "\n".join(lines)

    def _cmd_evidence(self, query: str) -> str:
        if not self.agent:
            return "Agent not initialized."
        if not query:
            return "Usage: /evidence <query>"
        r = self.agent.engine.execute("knowledge.evidence", query=query)
        if not r.success:
            return f"Error: {r.error}"
        lines = [f"  EVIDENCE: {query}", "  " + "-" * 55]
        for item in r.data[:10]:
            sf = item.get("source_file", "")
            if sf:
                sf = sf.split("\\")[-1]
            ls = item.get("line_start", 0)
            le = item.get("line_end", 0)
            text = item.get("text", "")[:200]
            lines.append(f"  {sf}:{ls}-{le}")
            if text:
                lines.append(f"    {text}")
        if not r.data:
            lines.append("  No evidence found.")
        return "\n".join(lines)

    def _cmd_inspect(self, symbol: str) -> str:
        if not self.agent:
            return "Agent not initialized."
        if not symbol:
            return "Usage: /inspect <symbol>"

        info = self.agent.inspect_symbol(symbol)
        if not info.get("found"):
            return f"  Symbol not found: {symbol}"

        lines = [
            f"  SYMBOL: {symbol}",
            "  " + "-" * 55,
            f"  Kind:       {info.get('kind', 'unknown')}",
            f"  Module:     {info.get('module', 'unknown')}",
            f"  Files:      {len(info.get('files', []))}",
        ]
        for f in info.get("files", []):
            lines.append(f"    {f}")

        callees = info.get("callees", [])
        lines.append(f"  Calls:      {len(callees)}")
        for c in callees[:10]:
            lines.append(f"    -> {c}")

        callers = info.get("callers", [])
        lines.append(f"  Called by:  {len(callers)}")
        for c in callers[:10]:
            lines.append(f"    <- {c}")

        uses = info.get("uses", [])
        lines.append(f"  Uses:       {len(uses)}")
        for u in uses[:10]:
            lines.append(f"    ~ {u}")

        lines.append(f"  Facts:      {info.get('facts_count', 0)}")
        lines.append(f"  Evidence:   {info.get('evidence_count', 0)}")
        lines.append(f"  Relations:  {info.get('relation_count', 0)}")

        return "\n".join(lines)

    def _cmd_trace(self, cmd: str) -> str:
        if not self.agent:
            return "Agent not initialized."
        parts = cmd.split()
        trace_id = parts[1] if len(parts) > 1 else None

        if trace_id:
            steps = self.agent.get_persisted_trace(trace_id)
        else:
            steps = self.agent.get_persisted_trace()

        if not steps:
            return "  No trace available. Ask a question first."

        lines = ["  EXECUTION TRACE", "  " + "-" * 55]
        for s in steps:
            step = s.get("step", "")
            comp = s.get("component", "")
            op = s.get("operation", "")
            inp = s.get("input_summary", "")[:80]
            out = s.get("output_summary", "")[:80]
            dur = s.get("duration_ms", 0)
            status = s.get("status", "")
            lines.append(f"  [{step}] {comp}.{op} ({dur:.0f}ms) [{status}]")
            lines.append(f"    in:  {inp}")
            lines.append(f"    out: {out}")
        return "\n".join(lines)

    def _cmd_plan(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        plans = list(self.agent.state.plans.values())
        if not plans:
            return "  No plans yet."
        last = plans[-1]
        lines = [
            f"  PLAN: {last.plan_id}",
            "  " + "-" * 55,
            f"  Goal:   {last.goal}",
            f"  Intent: {last.intent}",
            f"  Status: {last.status}",
            f"  Steps:  {len(last.steps)}",
        ]
        for i, s in enumerate(last.steps):
            action = s.get("action", "")
            tool = s.get("tool", "")
            params = s.get("params", {})
            deps = s.get("depends_on", [])
            dep_str = f" <- {deps}" if deps else ""
            lines.append(f"  {i}: {action} [{tool}]{dep_str}")
            if params:
                lines.append(f"     {params}")
        return "\n".join(lines)

    def _cmd_session(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        session = self.agent.state.get_session()
        if not session:
            return "  No active session."
        info = session.to_dict()
        lines = [
            "  SESSION",
            "  " + "-" * 55,
            f"  ID:       {info['session_id']}",
            f"  Turns:    {info['turn_count']}",
            f"  Topic:    {info['active_topic'] or '(none)'}",
            f"  Symbols:  {info['active_symbols']}",
            f"  Files:    {info['active_files']}",
        ]
        return "\n".join(lines)

    def _cmd_context(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        stats = self.agent.get_conversation_stats()
        recent = self.agent.conversation.get_recent_context(3)
        lines = [
            "  ACTIVE CONTEXT",
            "  " + "-" * 55,
            f"  Topic:   {stats.get('active_topic', '')}",
            f"  Symbols: {stats.get('active_symbols', {})}",
            f"  Turns:   {stats.get('total_turns', 0)}",
        ]
        if recent:
            lines.append("")
            lines.append(recent)
        return "\n".join(lines)

    def _cmd_graph(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        stats = self.agent.get_symbol_graph_stats()
        lines = [
            "  SYMBOL GRAPH",
            "  " + "-" * 55,
            f"  Symbols:     {stats['symbols']}",
            f"  Relations:   {stats['relations']}",
            f"  Built:       {stats['built']}",
        ]
        if stats.get("kinds"):
            lines.append("  Kinds:")
            for k, v in sorted(stats["kinds"].items(), key=lambda x: -x[1]):
                lines.append(f"    {k:20s} {v}")
        if stats.get("relation_types"):
            lines.append("  Relation types:")
            for k, v in sorted(stats["relation_types"].items(), key=lambda x: -x[1]):
                lines.append(f"    {k:20s} {v}")
        return "\n".join(lines)

    def _cmd_web(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        print("  BUILT KNOWLEDGE WEB...")
        stats = self.agent.get_knowledge_web_stats()
        web = self.agent.get_knowledge_web()
        integ = web.integrity_report()
        lines = [
            "  KNOWLEDGE WEB + COVERAGE",
            "  " + "-" * 55,
            f"  Nodes:        {stats.get('nodes')}",
            f"  Edges:        {stats.get('edges')}",
            f"  KCS (all):    {stats.get('kcs')}%",
            f"  DENSITY(top): {stats.get('density')}%",
            f"  Orphan:       {stats.get('orphan_rate')}%",
            "  COVERAGE (top-level symbols, 9 coeff):",
        ]
        cov = stats.get("coverage", {})
        for k, v in cov.items():
            lines.append(f"    {k:16s} {v}%")
        lines.append("  Levels (>= level, top-level):")
        lev = stats.get("levels", {})
        for i in range(0, 11):
            lines.append(f"    L{i:>2} {lev.get(str(i), 0)}%")
        lines.append("  KNOWLEDGE INTEGRITY:")
        lines.append(f"    dangling_relations: {integ.get('dangling_relations')}")
        lines.append(f"    dangling_concepts:  {integ.get('dangling_concepts')}")
        return "\n".join(lines)

    def _cmd_conversation(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        snapshot = self.agent.conversation.snapshot()
        lines = ["  CONVERSATION HISTORY", "  " + "-" * 55]
        for turn in snapshot.get("turns", []):
            q = turn.get("question", "")
            a = turn.get("answer", "")[:80]
            symbols = turn.get("symbols", [])
            verified = turn.get("verified", False)
            v = "VERIFIED" if verified else "UNVERIFIED"
            lines.append(f"  Q: {q}")
            lines.append(f"  A: {a}... [{v}]")
            if symbols:
                lines.append(f"  Symbols: {', '.join(symbols)}")
            lines.append("")
        if not snapshot.get("turns"):
            lines.append("  No conversation yet.")
        return "\n".join(lines)

    def _cmd_state(self) -> str:
        if not self.agent:
            return "Agent not initialized."
        stats = self.agent.get_state_stats()
        exec_stats = self.agent.engine.get_stats()
        lines = [
            "  PERSISTENT STATE",
            "  " + "-" * 55,
            f"  Sessions:    {stats['sessions']}",
            f"  Turns:       {stats['turns']}",
            f"  Plans:       {stats['plans']}",
            f"  Executions:  {stats['executions']}",
            f"  Evidence:    {stats['evidence']}",
            f"  Traces:      {stats['traces']}",
            "",
            "  EXECUTION STATS",
            "  " + "-" * 55,
            f"  Total:       {exec_stats['total_executions']}",
            f"  Success:     {exec_stats['success']}",
            f"  Errors:      {exec_stats['errors']}",
            f"  Avg time:    {exec_stats['avg_duration_ms']:.1f}ms",
        ]
        return "\n".join(lines)

    def _cmd_clear(self):
        os.system("cls" if os.name == "nt" else "clear")
        print(BANNER)
        return None

    def _cmd_reset(self):
        if self.agent:
            self.agent.conversation.clear()
        return "  Conversation reset."

    def _cmd_help(self):
        print(HELP_TEXT)
        return None

    def _cmd_ask(self, question: str) -> str:
        if not self.agent:
            return "Agent not initialized."

        print(f"\n  Processing: {question}...")

        result = self.agent.execute(question)

        answer = result.get("answer", "No answer generated.")
        verified = result.get("verified", False)
        confidence = result.get("confidence", 0.0)
        intent = result.get("intent", "unknown")
        latency = result.get("latency_ms", 0)

        v_status = "VERIFIED" if verified else "UNVERIFIED"
        lines = [
            f"\n  [{v_status}] confidence={confidence:.0%} intent={intent} [{latency:.0f}ms]",
            "",
            answer,
        ]

        prov = result.get("provenance", [])
        if prov:
            sources = [f"{p['type']}({p['count']})" for p in prov]
            lines.append(f"\n  Provenance: {', '.join(sources)}")

        ver = result.get("verification", "")
        if ver:
            lines.append(f"\n  {ver}")

        turn_id = result.get("turn_id", "")
        plan_id = result.get("plan_id", "")
        if turn_id:
            lines.append(f"\n  Turn: {turn_id} Plan: {plan_id}")

        return "\n".join(lines)


def main():
    cli = AgentCLI()
    cli.boot()

    single_shot = None
    if len(sys.argv) > 1:
        single_shot = " ".join(sys.argv[1:])

    if single_shot:
        print(f"\n  B+ > {single_shot}")
        result = cli.handle_command(single_shot)
        if result:
            print()
            print(result)
            print()
        return

    print("  Type your question, or /help for commands.\n")

    while True:
        try:
            line = input("B+ > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n  Goodbye.")
            break

        if not line:
            continue

        result = cli.handle_command(line)
        if result == "EXIT":
            print("  Goodbye.")
            break
        if result:
            print()
            print(result)
            print()


if __name__ == "__main__":
    main()
