# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Reads flutter's json reporter output per test file, whether a file ran alone or bundled."""
import collections
import json
import os

import client_shards


def results(lines, bundles):
    """{test file: Counter of (test name, outcome)} from flutter's json reporter."""
    groups = {f for files in bundles.values() for f in files}
    suites, tests, finished = {}, {}, set()
    out = collections.defaultdict(collections.Counter)
    for line in lines:
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if "suite" in event:
            path = event["suite"]["path"]
            suites[event["suite"]["id"]] = (relative(path), f"loading {path}")
        elif event.get("type") == "testStart":
            test = event["test"]
            suite, loader = suites.get(test["suiteID"], ("?", None))
            tests[test["id"]] = (suite, test["name"], test["name"] == loader)
        elif event.get("type") == "testDone" and event["testID"] in tests:
            finished.add(event["testID"])
            if event.get("hidden") and event["result"] == "success":
                continue
            outcome = "skipped" if event.get("skipped") else event["result"]
            _record(out, tests[event["testID"]], outcome, bundles, groups)
        elif event.get("type") == "error" and event.get("testID") in finished:
            _record(out, tests[event["testID"]], "error after it finished", bundles, groups)
    return out


def _record(out, test, outcome, bundles, groups):
    """Files a test under its own file: a bundle's group name is that file's path."""
    suite, name, loading = test
    if suite in bundles and loading:
        for f in bundles[suite]:
            out[f][("loading", outcome)] += 1
        return
    path, _, rest = name.partition(" ")
    if suite in bundles and path in groups:
        out[path][(rest, outcome)] += 1
    else:
        out[suite][("loading" if loading else name, outcome)] += 1


def differences(per_file, bundled, files):
    """[(file, what only the per-file run saw, what only the bundled run saw)]."""
    rows = []
    for f in sorted(files):
        alone, together = clean(per_file.get(f)), clean(bundled.get(f))
        if alone != together:
            rows.append((f, alone - together, together - alone))
    return rows


def clean(counter):
    """Drops the loading pseudo-test when it passed; bundles and files load differently."""
    counter = collections.Counter(counter or {})
    counter.pop(("loading", "success"), None)
    return counter


def suite_paths(lines):
    """The test files and bundles a json report ran, relative to packages/app."""
    events = (json.loads(line) for line in lines if line.startswith("{"))
    return {relative(e["suite"]["path"]) for e in events if "suite" in e}


def relative(path):
    return path.replace(os.sep, "/").split(client_shards._MARKER, 1)[-1]


def failed_files(counts):
    return {f for f, tests in counts.items()
            if any(outcome in ("failure", "error", "error after it finished")
                   for _, outcome in tests)}


def report(per_file_lines, bundled_lines, bundles):
    """Prints every bundled file whose results differ; returns how many do."""
    per_file = results(per_file_lines, bundles)
    bundled = results(bundled_lines, bundles)
    members = {m for fs in bundles.values() for m in fs}
    seen = {f for f in set(bundled) | set(per_file) if f in members}
    rows = differences(per_file, bundled, seen)
    for f, only_alone, only_bundled in rows:
        print(f"DIFFERS {f}")
        for (name, outcome), n in sorted(only_alone.items(), key=str):
            print(f"  per-file only: {outcome} x{n}: {name}")
        for (name, outcome), n in sorted(only_bundled.items(), key=str):
            print(f"  bundled only:  {outcome} x{n}: {name}")
    tests = sum(sum(clean(bundled.get(f)).values()) for f in seen)
    print(f"{len(rows)} of {len(seen)} bundled files ({tests} tests) differ from their per-file run")
    return len(rows)
