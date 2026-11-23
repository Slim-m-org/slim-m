# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Scores whisper's raw text from the wake-phrase corpus with the card's parser rules."""
import json, re, sys
from collections import defaultdict
from pathlib import Path

FILLERS = {"please", "um", "uh", "okay", "ok"}
MARK = {"mark", "bookmark", "clip"}
OBJECTS = {"that", "this", "it"}
ARM_MS = 10_000

def norm(text):
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", text.lower())).strip().split()

def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

def word_ok(heard, want, aliases):
    if heard == want or heard in aliases.get(want, ()): return True
    return len(want) >= 4 and edits(heard, want) <= 1

def find_phrase(words, phrase, aliases):
    n = len(phrase)
    for i in range(len(words) - n + 1):
        if all(word_ok(words[i + k], phrase[k], aliases) for k in range(n)):
            return i + n
    return None

def verb(rest):
    if rest and rest[0] in FILLERS: rest = rest[1:]
    if not rest: return None
    if rest[0] in MARK: return ("mark", None)
    if rest[0] == "note" and len(rest) > 1: return ("note", " ".join(rest[1:])[:500])
    return None

def parse(text, phrase, aliases):
    words = norm(text)
    end = find_phrase(words, phrase, aliases)
    if end is None: return ("none", None)
    rest = words[end:]
    if not rest or all(w in FILLERS for w in rest): return ("wake", None)
    return verb(rest) or ("none", None)

def under_cwd(arg):
    """A path argument, refused unless it stays inside the working directory."""
    base = Path.cwd().resolve()
    path = (base / arg).resolve()
    if not path.is_relative_to(base):
        raise SystemExit(f"{arg}: outside the working directory")
    return path

def accepted_kind(row, phrase, aliases):
    """What a clip made the parser act on: "mark", "note" or None."""
    armed_until = -1
    for u in row["heard"]:
        kind, _ = parse(u["text"], phrase, aliases)
        if kind == "wake":
            armed_until = u["voiced_end_ms"] + ARM_MS
            continue
        if kind == "none" and u["start_ms"] <= armed_until:
            kind = (verb(norm(u["text"])) or ("none",))[0]
        if kind in ("mark", "note"):
            return kind
    return None

def run(rows, manifest, phrase, aliases):
    stats = defaultdict(lambda: [0, 0])
    false_accepts, misses, neg_seconds = [], [], 0.0
    for row in rows:
        meta = manifest[row["file"]]
        got = accepted_kind(row, phrase, aliases)
        heard = [u["text"] for u in row["heard"]]
        if meta["expect"] == "none":
            neg_seconds += meta["seconds"]
            if got:
                false_accepts.append((row["file"], heard))
            continue
        ok = got == meta["expect"]
        stats[meta["cond"]][0] += ok
        stats[meta["cond"]][1] += 1
        if not ok:
            misses.append((row["file"], got, heard))
    return stats, false_accepts, misses, neg_seconds

if __name__ == "__main__":
    manifest = {m["file"]: m for m in json.loads(under_cwd(sys.argv[1]).read_text())}
    rows = [json.loads(l) for l in under_cwd(sys.argv[2]).read_text().splitlines()]
    aliases = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    stats, fa, misses, neg_s = run(rows, manifest, ["hey", "space"], aliases)
    tot = [sum(v[0] for v in stats.values()), sum(v[1] for v in stats.values())]
    print("accepted", tot, {k: f"{v[0]}/{v[1]}" for k, v in sorted(stats.items())})
    print("false accepts", len(fa), "over", round(neg_s / 60, 1), "min of negatives =", round(len(fa) / (neg_s / 3600), 2), "per hour")
    for f in fa: print("  FA", f)
    for m in misses: print("  MISS", m)
