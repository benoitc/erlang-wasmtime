# A hornbeam-style agent as a component (bench/agent_bench.erl). The
# context selects what a request does:
#   {"n": 100}               json work and one capability call
#   {"mode": "counter"}      a module global, incremented per request
#   {"mode": "calls", "n": N} N capability calls
#   {"mode": "loop"}         never returns
import json
import wit_world
from wit_world.imports import caps

counter = 0


class WitWorld(wit_world.WitWorld):
    def handle(self, context: str) -> str:
        global counter
        ctx = json.loads(context)
        mode = ctx.get("mode", "json")
        if mode == "counter":
            counter += 1
            return json.dumps({"ok": counter})
        if mode == "calls":
            for _ in range(ctx["n"]):
                caps.call("echo", b"x")
            return json.dumps({"ok": None})
        if mode == "loop":
            while True:
                pass
        doc = json.loads(json.dumps({"items": list(range(ctx["n"]))}))
        total = sum(doc["items"])
        cap = caps.call("echo", json.dumps({"sum": total}).encode())
        return json.dumps({"ok": {"sum": total, "cap": cap.decode()}})
