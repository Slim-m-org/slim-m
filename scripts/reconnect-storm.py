#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Drops every socket at once and asks how the server takes the herd coming back.

`docs/sizing.md` lists reconnect storms under what it did not measure, with
the note that this is how services usually fall over. The capacity study
measured a server under steady load; it never measured one the moment after
it restarts, which is the shape every deployment actually meets - `main` is
continuously deployed here, so a Watchtower restart drops every connected
client simultaneously and they all come back at once.

The interesting part is not the sockets. It is `/auth/ws-ticket`: a ticket is
single-use, so every returning client must mint one before it can reconnect,
and that route is rate limited per account. A storm therefore tests the
limiter far harder than it tests the connection handling, and the failure
mode to look for is a client that is refused a ticket, backs off, and takes
far longer to return than the socket itself needed.

Run it against a local server. Never against production: it is
indistinguishable from abuse.

    scripts/reconnect-storm.py --base-url http://127.0.0.1:8080 --users 60
"""
import argparse
import asyncio
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))

import e2e_api  # noqa: E402
import load_accounts  # noqa: E402
import load_report  # noqa: E402
import load_ws  # noqa: E402
import loadtest  # noqa: E402
import seed_guard  # noqa: E402

DEFAULT_PASSWORD = "loadtest-stable-password-1"
SETTLE = 2.0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--users", type=int, default=60)
    parser.add_argument("--per-account", type=int, default=1,
                        help="sockets each account holds")
    parser.add_argument("--rounds", type=int, default=3,
                        help="how many times to drop and re-open everything")
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--invite-code", default=None)
    parser.add_argument("--cache-dir", default=".")
    parser.add_argument("--out", default="reconnect-storm-result.json")
    parser.add_argument("--server-pid", type=int, default=None)
    return parser.parse_args(argv)


def build_subscribers(accounts, base_url, ws_url, per_account):
    """One [`load_ws.Subscriber`] per socket the run wants to hold."""
    subscribers = []
    for account in accounts:
        for n in range(max(1, per_account)):
            api = e2e_api.Api(base_url, token=account["api"].token)
            subscribers.append(
                load_ws.Subscriber(f"{account['username']}#{n}", api, ws_url))
    return subscribers


async def open_one(subscriber):
    """Opens one socket, returning how long it took or None if it failed.

    A reconnect is a ticket plus a handshake, and the ticket is the half a
    storm strains, so this times both together: what a returning client
    experiences is the sum, not the socket alone.
    """
    started = time.monotonic()
    ok = await subscriber.open()
    if not ok:
        return None
    return (time.monotonic() - started) * 1000.0


async def storm(subscribers):
    """Opens every socket at once, with no gate. That is the whole point.

    `load_ws.connect_all` deliberately bounds concurrency so an ordinary run
    measures the server rather than a thundering herd it created itself. Here
    the herd is the subject, so the bound is removed.
    """
    started = time.monotonic()
    timings = await asyncio.gather(*(open_one(s) for s in subscribers))
    wall = time.monotonic() - started
    opened = [ms for ms in timings if ms is not None]
    failures = [f"{s.name}: {s.failure}" for s in subscribers if s.failure]
    return opened, failures, wall


async def drop_all(subscribers):
    """Cuts every socket the way a server restart does, not politely.

    A graceful close tells the server the client is going; a restart, a
    dropped tunnel or a killed process does not. Aborting the transport is
    the closer analogue, and it matters because the server's own cleanup path
    differs between the two.

    Deliberately not wrapped in a bare `except`. `transport` is an instance
    attribute websockets sets in `connection_made`, so it is not visible on
    the class and a defensive try/except here would turn a future rename into
    a run that quietly measures nothing: every socket would stay up, every
    "reconnect" would be an already-open socket returning instantly, and the
    numbers would look excellent. Better to fail.
    """
    live = [s for s in subscribers if s.connected]
    if not live:
        raise RuntimeError("nothing to drop; the previous round connected none")
    for subscriber in live:
        subscriber.ws.transport.abort()
        subscriber.connected = False
        subscriber.failure = None
    # The close still has to reach the server before it frees the slot.
    await asyncio.sleep(0.5)
    still_open = [s.name for s in live if not s.ws.transport.is_closing()]
    if still_open:
        raise RuntimeError(
            f"{len(still_open)} socket(s) did not drop, e.g. {still_open[0]}; "
            "a storm that never happened would report perfect reconnects")


def summarise_round(index, opened, failures, wall, attempted):
    return {
        "round": index,
        "attempted": attempted,
        "reconnected": len(opened),
        "refused": attempted - len(opened),
        "wall_seconds": round(wall, 2),
        "reconnect_ms": load_report.summarise(opened),
        "failures": failures[:5],
        "failure_count": len(failures),
    }


async def run(args):
    print(f"setting up {args.users} accounts (cached where possible)...",
          flush=True)
    accounts, from_cache = load_accounts.obtain(
        args.base_url, args.users, args.password, args.invite_code,
        args.cache_dir)
    source = "from cache" if from_cache else "freshly registered"
    print(f"  {len(accounts)} accounts ready ({source})", flush=True)

    ws_url = loadtest.ws_url_for(args.base_url)
    admin = accounts[0]["api"]
    subscribers = build_subscribers(
        accounts, args.base_url, ws_url, args.per_account)
    attempted = len(subscribers)

    before = loadtest.scrape(admin)
    cpu_before = loadtest.server_cpu()
    wall_before = time.monotonic()

    rounds = []
    print(f"opening {attempted} sockets, ungated...", flush=True)
    opened, failures, wall = await storm(subscribers)
    rounds.append(summarise_round(0, opened, failures, wall, attempted))
    print(f"  round 0: {len(opened)}/{attempted} in {wall:.1f}s", flush=True)

    for index in range(1, args.rounds + 1):
        await asyncio.sleep(SETTLE)
        await drop_all(subscribers)
        print(f"dropped every socket; round {index} returning at once...",
              flush=True)
        opened, failures, wall = await storm(subscribers)
        rounds.append(
            summarise_round(index, opened, failures, wall, attempted))
        print(f"  round {index}: {len(opened)}/{attempted} in {wall:.1f}s",
              flush=True)

    await asyncio.sleep(SETTLE)
    cpu_used = (loadtest.server_cpu() or 0) - (cpu_before or 0)
    elapsed = time.monotonic() - wall_before
    after = loadtest.scrape(admin)
    await asyncio.gather(*(s.close() for s in subscribers),
                         return_exceptions=True)

    worst = max((r["reconnect_ms"].get("max") or 0) for r in rounds)
    report = {
        "scenario": "reconnect-storm",
        "config": {
            "users": len(accounts),
            "per_account": args.per_account,
            "sockets": attempted,
            "rounds": args.rounds,
        },
        "rounds": rounds,
        "worst_reconnect_ms": worst,
        "every_socket_returned": all(
            r["reconnected"] == attempted for r in rounds),
        "server": {
            "delta": load_report.counter_delta(before, after),
            "rss_end_bytes": (after or {}).get(
                "slimm_process_resident_memory_bytes"),
            "ws_connections_end": (after or {}).get(
                "slimm_websocket_connections"),
            "cpu_seconds": round(cpu_used, 3) if cpu_used else None,
            "wall_seconds": round(elapsed, 2),
            "cpu_percent_of_one_core": (round(100 * cpu_used / elapsed, 1)
                                        if cpu_used and elapsed else None),
        },
    }
    load_report.write(report, args.out)
    print()
    print(render(report))
    print(f"\nwrote {args.out}")
    return report


def render(report):
    lines = [f"scenario: {report['scenario']}"]
    config = report["config"]
    lines.append(f"  sockets={config['sockets']} "
                 f"({config['users']} accounts x {config['per_account']}) "
                 f"rounds={config['rounds']}")
    for entry in report["rounds"]:
        stat = entry["reconnect_ms"]
        label = "initial" if entry["round"] == 0 else f"round {entry['round']}"
        if not stat.get("count"):
            lines.append(f"  {label}: nothing connected")
            continue
        lines.append(
            f"  {label}: {entry['reconnected']}/{entry['attempted']} back in "
            f"{entry['wall_seconds']}s, p50={stat['p50']}ms "
            f"p95={stat['p95']}ms max={stat['max']}ms "
            f"refused={entry['refused']}")
        for note in entry["failures"]:
            lines.append(f"    {note}")
    server = report["server"]
    for key in ("cpu_seconds", "cpu_percent_of_one_core", "rss_end_bytes",
                "ws_connections_end"):
        if server.get(key) is not None:
            lines.append(f"  server {key}: {server[key]}")
    for key in sorted(server.get("delta", {})):
        if "_bucket{" in key:
            continue
        lines.append(f"  server {key}: +{server['delta'][key]}")
    return "\n".join(lines)


def main(argv=None):
    args = parse_args(argv)
    if seed_guard.is_known_production(args.base_url):
        raise SystemExit("refusing to storm the live deployment")
    loadtest._SERVER_PID["pid"] = args.server_pid or loadtest.find_server_pid()
    asyncio.run(run(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
