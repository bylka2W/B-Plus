import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import MEMORY_DIR, save_json

TELEMETRY_PATH = MEMORY_DIR / "telemetry.json"
MAX_EVENTS = 1000

PERF_GATES = {
    "simple": {
        "p50_ms": 100,
        "p95_ms": 500,
        "max_ms": 1000,
        "max_tool_calls": 3,
        "max_grep": 0,
    },
    "normal": {
        "p50_ms": 500,
        "p95_ms": 2000,
        "max_ms": 5000,
        "max_tool_calls": 8,
        "max_grep": 0,
    },
    "complex": {
        "p50_ms": 5000,
        "p95_ms": 15000,
        "max_ms": 30000,
        "max_tool_calls": 12,
        "max_grep": 1,
    },
    "hard": {
        "p50_ms": 15000,
        "p95_ms": 30000,
        "max_ms": 60000,
        "max_tool_calls": 20,
        "max_grep": 2,
    },
}


class Telemetry:
    def __init__(self, events=None):
        self.events = events or []
        self._response_times = []
        self._dirty = False
        self._save_interval = 50
        self._since_save = 0

    @classmethod
    def load(cls):
        if TELEMETRY_PATH.exists():
            try:
                with open(TELEMETRY_PATH, "r", encoding="utf-8") as f:
                    doc = json.load(f)
                return cls(doc.get("events", []))
            except (json.JSONDecodeError, OSError):
                pass
        return cls()

    def save(self):
        events = self.events[-MAX_EVENTS:]
        doc = {
            "schema": "telemetry",
            "version": 1,
            "events": events,
        }
        save_json(TELEMETRY_PATH, doc)
        self._dirty = False
        self._since_save = 0

    def flush(self):
        if self._dirty:
            self.save()

    def record(self, event):
        event.setdefault("timestamp", time.time())
        self.events.append(event)
        if "total_ms" in event:
            self._response_times.append(event["total_ms"])
        self._dirty = True
        self._since_save += 1
        if self._since_save >= self._save_interval:
            self.save()

    def record_question(self, question, bundle_dict, budget=None):
        event = {
            "timestamp": time.time(),
            "type": "question",
            "question": question,
            "status": bundle_dict.get("status"),
            "intent": bundle_dict.get("intent"),
            "confidence": bundle_dict.get("confidence"),
            "completeness": bundle_dict.get("completeness"),
            "routing_ms": bundle_dict.get("telemetry", {}).get("routing_ms", 0),
            "query_ms": bundle_dict.get("telemetry", {}).get("query_ms", 0),
            "answer_ms": bundle_dict.get("telemetry", {}).get("answer_ms", 0),
            "total_ms": bundle_dict.get("telemetry", {}).get("total_ms", 0),
            "evidence_count": len(bundle_dict.get("evidence", [])),
            "claims_count": len(bundle_dict.get("claims", [])),
            "cache_hit": bundle_dict.get("cache_hit", False),
        }
        if budget:
            event["budget"] = budget.budget_summary()
        self.record(event)
        return event

    def percentile(self, p, last_n=None):
        if last_n is not None and last_n <= 0:
            return 0.0
        times = self._response_times[-last_n:] if last_n else self._response_times
        if not times:
            return 0.0
        s = sorted(times)
        idx = int(len(s) * p / 100.0)
        idx = min(idx, len(s) - 1)
        return s[idx]

    def stats(self, last_n=100):
        recent = self.events[-last_n:] if last_n else self.events
        if not recent:
            return {"count": 0}
        times = [e.get("total_ms", 0) for e in recent if "total_ms" in e]
        statuses = {}
        for e in recent:
            s = e.get("status", "unknown")
            statuses[s] = statuses.get(s, 0) + 1
        intents = {}
        for e in recent:
            i = e.get("intent", "unknown")
            intents[i] = intents.get(i, 0) + 1
        avg_ms = sum(times) / len(times) if times else 0
        return {
            "count": len(recent),
            "with_time": len(times),
            "avg_ms": round(avg_ms, 1),
            "p50_ms": round(self.percentile(50, last_n), 1),
            "p95_ms": round(self.percentile(95, last_n), 1),
            "max_ms": round(max(times) if times else 0, 1),
            "statuses": statuses,
            "intents": intents,
        }

    def check_gates(self, last_n=100):
        stats = self.stats(last_n)
        violations = []
        if not stats.get("with_time"):
            return {"passed": True, "violations": [], "stats": stats}
        for complexity, gates in PERF_GATES.items():
            count = stats["statuses"].get(complexity, 0)
            if count == 0:
                continue
            if stats["p50_ms"] > gates["p50_ms"] * 1.5:
                violations.append({
                    "complexity": complexity,
                    "metric": "p50_ms",
                    "actual": stats["p50_ms"],
                    "gate": gates["p50_ms"],
                })
            if stats["p95_ms"] > gates["p95_ms"] * 1.5:
                violations.append({
                    "complexity": complexity,
                    "metric": "p95_ms",
                    "actual": stats["p95_ms"],
                    "gate": gates["p95_ms"],
                })
            if stats["max_ms"] > gates["max_ms"]:
                violations.append({
                    "complexity": complexity,
                    "metric": "max_ms",
                    "actual": stats["max_ms"],
                    "gate": gates["max_ms"],
                })
        return {
            "passed": len(violations) == 0,
            "violations": violations,
            "stats": stats,
        }


def format_telemetry_stats(stats):
    if stats["count"] == 0:
        return "TELEMETRY: no events"
    lines = [
        f"TELEMETRY: {stats['count']} events ({stats['with_time']} timed)",
        f"  avg={stats['avg_ms']:.0f}ms p50={stats['p50_ms']:.0f}ms "
        f"p95={stats['p95_ms']:.0f}ms max={stats['max_ms']:.0f}ms",
    ]
    if stats.get("statuses"):
        parts = [f"{k}={v}" for k, v in stats["statuses"].items()]
        lines.append(f"  statuses: {', '.join(parts)}")
    return "\n".join(lines)


def main():
    t = Telemetry.load()
    stats = t.stats()
    print(format_telemetry_stats(stats))
    print("TELEMETRY MODULE READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
