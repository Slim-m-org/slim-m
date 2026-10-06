# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How much of the documented API a run actually touched.

Counted from what was really called rather than from a list kept by hand: the
API helper records every request it makes, and each browser is asked for its
own resource timings at the end, so the clients' traffic counts too. A list
kept by hand drifts the moment a scenario changes and then overstates coverage
for as long as nobody checks.
"""
import json
import re
from pathlib import Path

UUID = re.compile(r"/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
HEX = re.compile(r"/[0-9a-f]{32,64}")
CODE = re.compile(r"/invites/[A-Za-z0-9]{6,}")


def canon(path):
    """One route, however its ids were spelled."""
    path = path.split("?")[0]
    if len(path) > 1:
        path = path.rstrip("/")
    path = CODE.sub("/invites/{}", path)
    path = UUID.sub("/{}", path)
    path = HEX.sub("/{}", path)
    return re.sub(r"\{[^}]*\}", "{}", path)


def documented(schema_path):
    lines = Path(schema_path).read_text().splitlines()
    inside, paths = False, []
    for line in lines:
        if line.startswith("paths:"):
            inside = True
            continue
        if inside and line and not line[0].isspace():
            break
        if inside and re.match(r"^ {2}/", line):
            paths.append(line.strip().rstrip(":"))
    return paths


def from_browser(client, origin):
    """Every request the page itself made, which the harness never sees."""
    raw = client.ev(
        "JSON.stringify(performance.getEntriesByType('resource')"
        ".map(function(e){return e.name;}))")
    out = set()
    for url in json.loads(raw or "[]"):
        if origin not in url:
            continue
        out.add(canon(url.split(origin, 1)[1]))
    return out


def report(touched, schema_path):
    known = documented(schema_path)
    seen = {canon(p) for p in touched}
    covered = sorted({p for p in known if canon(p) in seen})
    missing = sorted({p for p in known if canon(p) not in seen})
    pct = 100 * len(covered) // max(len(known), 1)
    print(f"  {len(covered)}/{len(known)} documented API paths touched ({pct}%)")
    print(f"  not touched: {', '.join(missing) if missing else 'none'}")
    return covered, missing
