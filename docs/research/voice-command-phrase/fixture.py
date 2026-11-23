# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Writes the parser fixture: every distinct set of lines whisper heard, what the clip
said, and whether whisper lost the phrase or the verb (so no parser should act)."""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from score import parse, verb, norm, under_cwd

ALIASES = {"hey": ["pay", "hay"]}
manifest = {m["file"]: m for m in json.loads(under_cwd(sys.argv[1]).read_text())}
rows = [json.loads(l) for l in under_cwd(sys.argv[2]).read_text().splitlines()]

def acts(lines):
    armed = False
    for line in lines:
        kind, _ = parse(line, ["hey", "space"], ALIASES)
        if kind == "wake":
            armed = True
            continue
        if kind == "none" and armed:
            kind = (verb(norm(line)) or ("none",))[0]
        if kind in ("mark", "note"):
            return kind
    return "none"

seen = {}
for row in rows:
    meta = manifest[row["file"]]
    lines = [u["text"] for u in row["heard"] if u["text"].strip()]
    if not lines:
        continue
    entry = {"said": meta["said"], "heard": lines, "expect": meta["expect"]}
    if meta["expect"] != "none" and acts(lines) != meta["expect"]:
        entry["lost"] = True
    seen.setdefault(tuple(lines), entry)
out = sorted(seen.values(), key=lambda v: (v["expect"], v["said"], v["heard"]))
with under_cwd(sys.argv[3]).open("w") as dest:
    json.dump({"phrase": "hey space", "clips": out}, dest, indent=1, ensure_ascii=False)
print(len(out), "distinct clips,", sum(1 for v in out if v.get("lost")), "lost")
