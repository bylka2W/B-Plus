import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

WALL_CLOCK_LIMITS = {
    "simple": 1.0,
    "normal": 5.0,
    "complex": 30.0,
    "hard": 60.0,
}

TOOL_BUDGETS = {
    "simple": {
        "max_tool_calls": 3,
        "max_search_calls": 1,
        "max_source_reads": 2,
        "max_grep": 0,
        "max_llm_calls": 1,
    },
    "normal": {
        "max_tool_calls": 8,
        "max_search_calls": 3,
        "max_source_reads": 5,
        "max_grep": 0,
        "max_llm_calls": 2,
    },
    "complex": {
        "max_tool_calls": 12,
        "max_search_calls": 4,
        "max_source_reads": 8,
        "max_grep": 1,
        "max_llm_calls": 3,
    },
    "hard": {
        "max_tool_calls": 20,
        "max_search_calls": 6,
        "max_source_reads": 15,
        "max_grep": 2,
        "max_llm_calls": 4,
    },
}

CONTEXT_BUDGETS = {
    "simple": {
        "max_input_tokens": 1500,
        "max_output_tokens": 300,
        "max_evidence_items": 3,
        "max_claim_items": 5,
        "max_relation_items": 3,
    },
    "normal": {
        "max_input_tokens": 4000,
        "max_output_tokens": 800,
        "max_evidence_items": 6,
        "max_claim_items": 10,
        "max_relation_items": 8,
    },
    "complex": {
        "max_input_tokens": 12000,
        "max_output_tokens": 2000,
        "max_evidence_items": 12,
        "max_claim_items": 20,
        "max_relation_items": 20,
    },
    "hard": {
        "max_input_tokens": 25000,
        "max_output_tokens": 4000,
        "max_evidence_items": 20,
        "max_claim_items": 40,
        "max_relation_items": 40,
    },
}


class BudgetExceeded(Exception):
    def __init__(self, budget_type, current, limit, detail=None):
        self.budget_type = budget_type
        self.current = current
        self.limit = limit
        self.detail = detail
        msg = f"{budget_type}: {current} > {limit}"
        if detail:
            msg += f" ({detail})"
        super().__init__(msg)


class BudgetTracker:
    def __init__(self, complexity="normal", start_time=None):
        self.complexity = complexity
        self.start_time = start_time or time.monotonic()
        self.tool_calls = 0
        self.search_calls = 0
        self.source_reads = 0
        self.grep_calls = 0
        self.llm_calls = 0
        self.input_tokens_est = 0
        self.output_tokens_est = 0
        self._wall_limit = WALL_CLOCK_LIMITS.get(complexity, 60.0)
        self._tool_budget = TOOL_BUDGETS.get(complexity, TOOL_BUDGETS["normal"])
        self._context_budget = CONTEXT_BUDGETS.get(
            complexity, CONTEXT_BUDGETS["normal"]
        )

    def elapsed_sec(self):
        return time.monotonic() - self.start_time

    def elapsed_ms(self):
        return self.elapsed_sec() * 1000

    def remaining_sec(self):
        return max(0.0, self._wall_limit - self.elapsed_sec())

    def _check_wall(self):
        if self.elapsed_sec() > self._wall_limit:
            raise BudgetExceeded(
                "wall_clock", round(self.elapsed_sec(), 1),
                self._wall_limit, "timeout exceeded"
            )

    def check_tool(self, tool_type="generic"):
        self._check_wall()
        self.tool_calls += 1
        limit = self._tool_budget["max_tool_calls"]
        if self.tool_calls > limit:
            raise BudgetExceeded(
                "tool_calls", self.tool_calls, limit,
                f"type={tool_type}"
            )
        if tool_type == "search":
            self.search_calls += 1
            sl = self._tool_budget["max_search_calls"]
            if self.search_calls > sl:
                raise BudgetExceeded(
                    "search_calls", self.search_calls, sl
                )
        elif tool_type == "source_read":
            self.source_reads += 1
            rl = self._tool_budget["max_source_reads"]
            if self.source_reads > rl:
                raise BudgetExceeded(
                    "source_reads", self.source_reads, rl
                )
        elif tool_type == "grep":
            self.grep_calls += 1
            gl = self._tool_budget["max_grep"]
            if self.grep_calls > gl:
                raise BudgetExceeded(
                    "grep_calls", self.grep_calls, gl
                )
        elif tool_type == "llm":
            self.llm_calls += 1
            ll = self._tool_budget["max_llm_calls"]
            if self.llm_calls > ll:
                raise BudgetExceeded(
                    "llm_calls", self.llm_calls, ll
                )

    def check_context(self, input_tokens, output_tokens):
        self._check_wall()
        self.input_tokens_est += input_tokens
        self.output_tokens_est += output_tokens
        il = self._context_budget["max_input_tokens"]
        if self.input_tokens_est > il:
            raise BudgetExceeded(
                "input_tokens", self.input_tokens_est, il
            )
        ol = self._context_budget["max_output_tokens"]
        if self.output_tokens_est > ol:
            raise BudgetExceeded(
                "output_tokens", self.output_tokens_est, ol
            )

    def can_afford(self, tool_type="generic"):
        try:
            self.check_tool(tool_type)
            self.tool_calls -= 1
            if tool_type == "search":
                self.search_calls -= 1
            elif tool_type == "source_read":
                self.source_reads -= 1
            elif tool_type == "grep":
                self.grep_calls -= 1
            elif tool_type == "llm":
                self.llm_calls -= 1
            return True
        except BudgetExceeded:
            return False

    def is_expired(self):
        return self.elapsed_sec() > self._wall_limit

    def budget_summary(self):
        return {
            "complexity": self.complexity,
            "elapsed_ms": round(self.elapsed_ms(), 1),
            "wall_limit_sec": self._wall_limit,
            "remaining_ms": round(self.remaining_sec() * 1000, 1),
            "tool_calls": self.tool_calls,
            "tool_limit": self._tool_budget["max_tool_calls"],
            "search_calls": self.search_calls,
            "search_limit": self._tool_budget["max_search_calls"],
            "source_reads": self.source_reads,
            "source_limit": self._tool_budget["max_source_reads"],
            "grep_calls": self.grep_calls,
            "grep_limit": self._tool_budget["max_grep"],
            "llm_calls": self.llm_calls,
            "llm_limit": self._tool_budget["max_llm_calls"],
            "input_tokens_est": self.input_tokens_est,
            "input_limit": self._context_budget["max_input_tokens"],
            "output_tokens_est": self.output_tokens_est,
            "output_limit": self._context_budget["max_output_tokens"],
        }

    def remaining_budget(self):
        tb = self._tool_budget
        cb = self._context_budget
        return {
            "tool_calls": max(0, tb["max_tool_calls"] - self.tool_calls),
            "search_calls": max(0, tb["max_search_calls"] - self.search_calls),
            "source_reads": max(0, tb["max_source_reads"] - self.source_reads),
            "grep_calls": max(0, tb["max_grep"] - self.grep_calls),
            "llm_calls": max(0, tb["max_llm_calls"] - self.llm_calls),
            "input_tokens": max(0, cb["max_input_tokens"] - self.input_tokens_est),
            "output_tokens": max(0, cb["max_output_tokens"] - self.output_tokens_est),
            "wall_ms": round(self.remaining_sec() * 1000, 1),
        }


def format_budget(budget):
    s = budget.budget_summary()
    return (
        f"BUDGET[{s['complexity']}] "
        f"{s['elapsed_ms']:.0f}ms/{s['wall_limit_sec']*1000:.0f}ms | "
        f"tools={s['tool_calls']}/{s['tool_limit']} "
        f"search={s['search_calls']}/{s['search_limit']} "
        f"reads={s['source_reads']}/{s['source_limit']} "
        f"grep={s['grep_calls']}/{s['grep_limit']} "
        f"llm={s['llm_calls']}/{s['llm_limit']}"
    )


def main():
    for c in ("simple", "normal", "complex"):
        b = BudgetTracker(c)
        print(format_budget(b))
    print("BUDGET MODULE READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
