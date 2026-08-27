import time
import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class ConversationTurn:
    question: str
    answer: str
    intent: str
    entities: List[str] = field(default_factory=list)
    symbols: List[str] = field(default_factory=list)
    files: List[str] = field(default_factory=list)
    verified: bool = False
    confidence: float = 0.0
    tools_used: List[str] = field(default_factory=list)
    timestamp: float = 0.0
    duration_ms: float = 0.0


class ConversationState:
    def __init__(self, max_turns: int = 50):
        self.turns: List[ConversationTurn] = []
        self.max_turns = max_turns
        self.active_symbols: Dict[str, str] = {}
        self.active_files: Dict[str, str] = {}
        self.active_topic: str = ""
        self.session_start: float = time.monotonic()

    def add_turn(self, turn: ConversationTurn):
        self.turns.append(turn)
        if len(self.turns) > self.max_turns:
            self.turns = self.turns[-self.max_turns:]

        for symbol in turn.symbols:
            self.active_symbols[symbol] = turn.question
        for fl in turn.files:
            self.active_files[fl] = turn.question

        if turn.symbols:
            self.active_topic = turn.symbols[0]

    def resolve_reference(self, text: str) -> str:
        text_lower = text.lower()

        if any(w in text_lower for w in ["он", "она", "оно", "они", "it", "they", "he", "she"]):
            if self.active_topic:
                text = text.replace("он", self.active_topic)
                text = text.replace("она", self.active_topic)
                text = text.replace("оно", self.active_topic)
                text = text.replace("они", self.active_topic)

        if "тот же" in text_lower or "same" in text_lower:
            if self.active_topic:
                text = text.replace("тот же", self.active_topic)
                text = text.replace("same", self.active_topic)

        if "предыдущий" in text_lower or "previous" in text_lower:
            if self.turns:
                last = self.turns[-1]
                if last.symbols:
                    text = text.replace("предыдущий", last.symbols[0])

        return text

    def get_recent_context(self, n: int = 3) -> str:
        if not self.turns:
            return ""

        recent = self.turns[-n:]
        lines = []
        for t in recent:
            lines.append(f"Q: {t.question}")
            lines.append(f"A: {t.answer[:100]}")
            if t.symbols:
                lines.append(f"  symbols: {', '.join(t.symbols)}")
        return "\n".join(lines)

    def get_active_symbols(self) -> Dict[str, str]:
        return dict(self.active_symbols)

    def get_active_files(self) -> Dict[str, str]:
        return dict(self.active_files)

    def get_stats(self) -> Dict:
        return {
            "total_turns": len(self.turns),
            "active_symbols": len(self.active_symbols),
            "active_files": len(self.active_files),
            "active_topic": self.active_topic,
            "session_duration_s": round(time.monotonic() - self.session_start, 1),
        }

    def snapshot(self) -> Dict:
        return {
            "turns": [
                {
                    "question": t.question,
                    "answer": t.answer[:200],
                    "intent": t.intent,
                    "symbols": t.symbols,
                    "files": t.files,
                    "verified": t.verified,
                    "confidence": t.confidence,
                }
                for t in self.turns[-10:]
            ],
            "active_symbols": self.active_symbols,
            "active_files": self.active_files,
            "active_topic": self.active_topic,
            "stats": self.get_stats(),
        }

    def clear(self):
        self.turns.clear()
        self.active_symbols.clear()
        self.active_files.clear()
        self.active_topic = ""
        self.session_start = time.monotonic()
