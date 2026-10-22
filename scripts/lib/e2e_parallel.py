# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Run the Python e2e suite on several stacks at once and report as one.

Each shard is a whole `scripts/e2e.sh` run: its own server, LiveKit container,
web port, browser ports and work directory, given the scenarios
`e2e_groups.deal` dealt it. Called by scripts/e2e-parallel.sh, which has already
built the server and the web client so the shards share both.
"""
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time

import e2e_groups
import safe_paths
import e2e_run

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_WORK = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"),
    "slimm-e2e", "par")
OPT_IN = "(opt in with E2E_ONLY)"
# Ports per shard sit below the kernel's ephemeral range, clear of the serial defaults.
API, WEB, LK, RTC_TCP, RTC_UDP, CDP = 28100, 28200, 28300, 28400, 28500, 29000


def shard_env(index, work_root, port_base_shift=0):
    """The environment that points one e2e.sh at its own ports, container and work dir."""
    work = os.path.join(work_root, f"shard-{index}")
    shift = port_base_shift
    return {
        "E2E_WORK": work,
        "E2E_API_PORT": str(API + shift + index),
        "E2E_WEB_PORT": str(WEB + shift + index),
        "E2E_LK_PORT": str(LK + shift + index),
        "E2E_RTC_TCP_PORT": str(RTC_TCP + shift + index),
        "E2E_RTC_UDP_START": str(RTC_UDP + shift + index * 60),
        "E2E_RTC_UDP_END": str(RTC_UDP + shift + index * 60 + 50),
        "E2E_CDP_BASE": str(CDP + shift + index * 100),
        "E2E_LK_CONTAINER": f"slimm-e2e-par-{index}",
        "E2E_RESULTS": os.path.join(work, "results.json"),
        "E2E_ONLY_FILE": os.path.join(work, "only.json"),
        "E2E_SKIP_SERVER_BUILD": "1",
    }


def ports_in_use(env):
    busy = []
    for key in ("E2E_API_PORT", "E2E_WEB_PORT", "E2E_LK_PORT", "E2E_RTC_TCP_PORT"):
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", int(env[key]))) == 0:
                busy.append(f"{key}={env[key]}")
    return busy


def parse_shards(value):
    if value in (None, "", "auto"):
        return auto_shards()
    return max(1, int(value))


def auto_shards():
    """Four stacks on a roomy box; fewer when memory or cores cannot carry them."""
    cores = os.cpu_count() or 4
    try:
        with open("/proc/meminfo", encoding="utf-8") as fh:
            info = dict(line.split(":", 1) for line in fh)
        free_gb = int(info["MemAvailable"].split()[0]) / 1024 / 1024
    except (OSError, KeyError, ValueError):
        free_gb = 8
    # About 2.5 GB and 6 cores per stack: two to five browsers, a server and an SFU.
    return max(1, min(4, int(free_gb // 2.5), cores // 6))


def safe_work_dir(path):
    """The resolved work dir; shards write and clear trees under it, so it must sit inside the home dir or the repo."""
    work = safe_paths.confined(path, os.path.expanduser("~"), ROOT)
    if work == os.path.realpath(ROOT):
        raise SystemExit(f"--work must be a directory inside the repo, not the repo itself: {path}")
    return work


def start(index, env, names, log_dir):
    os.makedirs(env["E2E_WORK"], exist_ok=True)
    with open(env["E2E_ONLY_FILE"], "w", encoding="utf-8") as fh:
        json.dump(names, fh)
    log = open(os.path.join(log_dir, f"shard-{index}.log"), "wb")
    proc = subprocess.Popen(
        ["bash", os.path.join(ROOT, "scripts", "e2e.sh")],
        env={**os.environ, **env}, stdout=log, stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, start_new_session=True)
    return proc, log


def stop_all(procs):
    for proc, _ in procs:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
    deadline = time.time() + 60
    for proc, _ in procs:
        try:
            proc.wait(max(1, deadline - time.time()))
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)


def read_results(env):
    try:
        with open(env["E2E_RESULTS"], encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def merge(shards, names, codes):
    """One row per scenario: (name, shard, ok, seconds); a missing result is a failure."""
    rows, seen = [], set()
    for index, (env, assigned) in enumerate(shards):
        results = read_results(env) or []
        for row in results:
            seen.add(row["name"])
            rows.append((row["name"], index, row["ok"], row["seconds"]))
        for name in assigned:
            if name not in {r["name"] for r in results}:
                rows.append((name, index, False, 0.0))
                seen.add(name)
    order = {name: i for i, name in enumerate(names)}
    rows.sort(key=lambda r: order.get(r[0], 1 << 30))
    return rows


def report(rows, wall, shards, codes):
    failed = [r for r in rows if not r[2]]
    print(f"\n== parallel report: {len(rows)} scenarios on {len(shards)} stacks, "
          f"{wall / 60:.1f} min wall ==")
    for index, (_, assigned) in enumerate(shards):
        took = sum(r[3] for r in rows if r[1] == index)
        print(f"  shard {index}: {len(assigned)} scenarios, {took:.0f}s of scenario time, "
              f"exit {codes[index]}")
    print("\nslowest scenarios:")
    for name, index, ok, seconds in sorted(rows, key=lambda r: -r[3])[:15]:
        print(f"  {seconds:5.0f}s shard {index} {'ok  ' if ok else 'FAIL'} {name[:80]}")
    print()
    if failed or any(codes):
        print(f"FAIL: {len(failed)} scenario(s) failed")
        for name, index, _, _ in failed:
            print(f"  - {name} (shard {index}, log shard-{index}.log)")
        return 1
    print("PASS: every scenario, on every stack.")
    return 0


def record_durations(rows):
    known = e2e_groups.load_durations()
    known.update({name: seconds for name, _, ok, seconds in rows if ok})
    with open(e2e_groups.DURATIONS_FILE, "w", encoding="utf-8") as fh:
        json.dump(dict(sorted(known.items())), fh, indent=1)
        fh.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shards", default=os.environ.get("E2E_SHARDS", "auto"))
    parser.add_argument("--work", default=os.environ.get("E2E_PAR_WORK") or DEFAULT_WORK)
    parser.add_argument("--port-shift", type=int,
                        default=int(os.environ.get("E2E_PORT_SHIFT", "0")),
                        help="move every shard's ports, to run beside another parallel run")
    parser.add_argument("--record", action="store_true",
                        help="rewrite e2e_durations.json from this run's passes")
    parser.add_argument("--plan", action="store_true", help="print the deal and stop")
    args = parser.parse_args(argv)
    args.work = safe_work_dir(args.work)

    names = [n for n in e2e_run.scenario_names() if OPT_IN not in n]
    only = [o for o in os.environ.get("E2E_ONLY", "").split("|") if o]
    names = [n for n in names if e2e_run.selected(n, only, None)]
    count = parse_shards(args.shards)
    chunks = e2e_groups.deal(names, count)
    durations = e2e_groups.load_durations()
    for i, chunk in enumerate(chunks):
        guess = sum(durations.get(n, e2e_groups.UNKNOWN_SECONDS) for n in chunk)
        print(f"shard {i}: {len(chunk)} scenarios, about {guess:.0f}s")
    if args.plan:
        return 0

    os.makedirs(args.work, exist_ok=True)
    shards = [(shard_env(i, args.work, args.port_shift), chunk)
              for i, chunk in enumerate(chunks)]
    for env, _ in shards:
        busy = ports_in_use(env)
        if busy:
            print("ports already in use, so another run is up: " + ", ".join(busy))
            return 2

    began = time.time()
    procs = []
    try:
        for i, (env, chunk) in enumerate(shards):
            procs.append(start(i, env, chunk, args.work))
            time.sleep(3)
        codes = [proc.wait() for proc, _ in procs]
    except KeyboardInterrupt:
        print("interrupted; stopping the stacks")
        stop_all(procs)
        return 130
    finally:
        stop_all(procs)
        for _, log in procs:
            log.close()
    rows = merge(shards, names, codes)
    code = report(rows, time.time() - began, shards, codes)
    if args.record and code == 0:
        record_durations(rows)
    with open(os.path.join(args.work, "combined.json"), "w", encoding="utf-8") as fh:
        json.dump([{"name": n, "shard": i, "ok": ok, "seconds": s}
                   for n, i, ok, s in rows], fh, indent=1)
    return code


if __name__ == "__main__":
    sys.exit(main())
