import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from answer import AnswerEngine
from context import ContextBuilder
from router import Router
from verify import VerifyEngine


class Knowledge:
    def __init__(self, ae, router, ve=None):
        self.ae = ae
        self.router = router
        self.ve = ve or VerifyEngine(ae.cb)

    @classmethod
    def load(cls):
        cb = ContextBuilder.load()
        ae = AnswerEngine(cb)
        rt = Router(ae.cb.qe.search)
        ve = VerifyEngine(cb)
        return cls(ae, rt, ve)

    @property
    def cb(self):
        return self.ae.cb

    @property
    def verify_engine(self):
        return self.ve

    def route(self, question):
        return self.router.route(question)

    def ask(self, question):
        d = self.route(question)
        if d["status"] == "UNKNOWN_INTENT":
            m = self.ae.answer("__UNKNOWN__", "", question=question)
        else:
            m = self.ae.answer(d["intent"], d["entity"],
                               question=question)
        out = dict(m)
        out["schema"] = "knowledge_answer"
        out["version"] = 1
        out["routing"] = d
        out["status"] = m["status"]
        return out


def main():
    k = Knowledge.load()
    for q in [
        "Кто вызывает foldConstantOp?",
        "Где определён foldConstantOp?",
        "Покажи emit",
    ]:
        a = k.ask(q)
        print(f"{q!r:40} -> {a['status']:10} "
              f"conf={a['confidence']:11} "
              f"direct={str(a['direct_answer'])[:60]}")
    sys.exit(0)


if __name__ == "__main__":
    main()
