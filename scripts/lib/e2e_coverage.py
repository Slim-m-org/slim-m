# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How much of the documented API a run actually touched.

Counted from what was really called rather than from a list kept by hand: the
API helper records every request it makes, and the browsers' own traffic comes
from their DevTools network events, so the clients count too. A list kept by
hand drifts the moment a scenario changes and then overstates coverage for as
long as nobody checks.
"""
import re
import urllib.parse
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


def from_requests(urls, origin):
    """The API paths among the URLs the browsers requested, which the harness never sees."""
    wanted = urllib.parse.urlsplit(origin)
    out = set()
    for url in urls:
        got = urllib.parse.urlsplit(url)
        if (got.scheme, got.netloc) == (wanted.scheme, wanted.netloc):
            out.add(canon(got.path or "/"))
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
