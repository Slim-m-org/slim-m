#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Print the client packages whose tests a change can affect, one per line.

Reads changed file paths on stdin. A package is affected when a file under it changed or when
any package it depends on (transitively, through the workspace) is affected. A change to the
workspace pubspec, lockfile or analysis options affects every package. Only packages that
have a test/ directory are printed. Stdlib only, so it runs on a bare machine.
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
packages = root / "client" / "packages"
GLOBAL = ("client/pubspec.yaml", "client/pubspec.lock", "client/analysis_options.yaml")


def pubspec_names(path):
    text = path.read_text()
    name = re.search(r"^name:\s*(\S+)", text, re.M).group(1)
    deps = set(re.findall(r"^  (slimm_[a-z_]+):", text, re.M))
    return name, deps


info = {}
for d in sorted(p for p in packages.iterdir() if (p / "pubspec.yaml").exists()):
    info[d.name] = pubspec_names(d / "pubspec.yaml")
by_name = {name: d for d, (name, _) in info.items()}

changed = [line.strip() for line in sys.stdin if line.strip()]
hit = set()
if any(c in GLOBAL for c in changed):
    hit = set(info)
for c in changed:
    m = re.match(r"client/packages/([^/]+)/", c)
    if m and m.group(1) in info:
        hit.add(m.group(1))

grew = True
while grew:
    grew = False
    for d, (_, deps) in info.items():
        if d not in hit and any(by_name.get(dep) in hit for dep in deps):
            hit.add(d)
            grew = True

for d in sorted(hit):
    if (packages / d / "test").is_dir():
        print(f"client/packages/{d}")
