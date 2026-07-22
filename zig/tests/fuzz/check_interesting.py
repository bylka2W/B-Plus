import json
d = json.load(open(r"C:\B-Plus\zig\fuzz_report.json"))
for x in d["interesting_errors"]:
    print(f"  #{x['id']}: {x['detail']} stderr={x.get('stderr','?')[:100]}")
    print(f"    code: {x.get('code','?')[:150]}")
    print()
