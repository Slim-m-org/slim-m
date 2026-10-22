#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Which test files each packages/app CI shard runs, dealt by measured time.

  client_shards.py deal --shards 12 --index 0    print shard 0's files
  client_shards.py record run.json               rewrite client_durations.json

run.json is `flutter test --reporter json` output. Refresh the durations after
the suite changes a lot: `cd client/packages/app && flutter test
--reporter json --concurrency=2 > run.json`, then `record` it.
"""
import argparse
import json
import os
import sys

import safe_paths

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
APP_DIR = os.path.join(REPO, "client", "packages", "app")
DURATIONS_FILE = os.path.join(HERE, "client_durations.json")
# What a test file costs when no run has measured it yet.
UNKNOWN_SECONDS = 3.0
_MARKER = "client/packages/app/"


def test_files(app_dir=APP_DIR):
    found = []
    for root, _, names in os.walk(os.path.join(app_dir, "test")):
        for name in names:
            if name.endswith("_test.dart"):
                path = os.path.join(root, name)
                found.append(os.path.relpath(path, app_dir).replace(os.sep, "/"))
    return sorted(found)


def load_durations(path=DURATIONS_FILE):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def deal(files, shards, durations=None):
    """[files] dealt across [shards] lists, longest first into the emptiest."""
    durations = durations if durations is not None else load_durations()
    cost = {f: durations.get(f, UNKNOWN_SECONDS) for f in files}
    loads = [0.0] * shards
    dealt = [[] for _ in range(shards)]
    for f in sorted(files, key=lambda f: (-cost[f], f)):
        slot = loads.index(min(loads))
        loads[slot] += cost[f]
        dealt[slot].append(f)
    return [sorted(chunk) for chunk in dealt], loads


def seconds_per_file(events):
    """Load plus test time per test file, from flutter's json reporter events."""
    suites, started, spent = {}, {}, {}
    for event in events:
        if "suite" in event:
            suites[event["suite"]["id"]] = event["suite"]["path"]
        elif event.get("type") == "testStart":
            test = event["test"]
            started[test["id"]] = (test["suiteID"], event["time"])
        elif event.get("type") == "testDone" and event["testID"] in started:
            suite, begin = started[event["testID"]]
            spent[suite] = spent.get(suite, 0) + event["time"] - begin
    rows = {}
    for suite, ms in spent.items():
        path = suites.get(suite, "").replace(os.sep, "/")
        if _MARKER in path:
            rows[path.split(_MARKER, 1)[1]] = round(ms / 1000, 1)
    return dict(sorted(rows.items()))


def record(run_path, out_path=DURATIONS_FILE):
    run_path = safe_paths.home_or_cwd(run_path)
    with open(run_path, encoding="utf-8") as fh:
        events = [json.loads(line) for line in fh if line.startswith("{")]
    rows = seconds_per_file(events)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=0)
        fh.write("\n")
    return len(rows)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    dealer = sub.add_parser("deal")
    dealer.add_argument("--shards", type=int, required=True)
    dealer.add_argument("--index", type=int, required=True)
    rec = sub.add_parser("record")
    rec.add_argument("run_json")
    args = parser.parse_args(argv)
    if args.cmd == "record":
        print(f"recorded {record(args.run_json)} files")
        return 0
    if not 0 <= args.index < args.shards:
        parser.error("--index must be in [0, --shards)")
    dealt, _ = deal(test_files(), args.shards)
    print("\n".join(dealt[args.index]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
