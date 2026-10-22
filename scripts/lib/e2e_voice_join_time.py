# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Click to first remote audio, measured on the page for repeated joins.

Bob sits in the call publishing the fake tone. Alice joins and leaves it
JOIN_RUNS times; each join is stamped by e2e_join_probe_js on the page's own
clock, so the numbers are what a listener waits, not what a widget claims.
The target is a p50 of 1.5 s or less (docs/research/voice-experience-plan.md).
"""
import json
import math
import os
import time

import e2e_audio
import e2e_join_probe_js
import e2e_labels as L
import e2e_netem
from e2e_voice import _tap_label, participants_with_mics

# Cumulative stages in the order a sequential join reaches them.
STAGES = ("tokenStart", "tokenEnd", "wsStart", "wsOpen", "ice", "micRequested",
          "micOpened", "publishStart", "published", "firstPacket",
          "firstSamples")
TARGET_P50_MS = 1500
# Extra profiles for this scenario; the SFU's egress is all netem can shape here.
WAN_PROFILES = {"wan70": "delay 70ms 5ms"}
ARRIVAL_TIMEOUT = 25


def percentile(values, pct):
    """Nearest-rank percentile; None for an empty list."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(pct / 100 * len(ordered)))
    return ordered[rank - 1]


def relative(marks):
    """Each stage in ms from the click, dropping stages that never stamped."""
    if "click" not in marks:
        return {}
    start = marks["click"]
    return {k: round(marks[k] - start, 1) for k in STAGES if k in marks}


def summarize(runs):
    """`{stage: (p50, p95, n)}` over runs given as relative() dicts."""
    out = {}
    for stage in STAGES:
        values = [r[stage] for r in runs if stage in r]
        if values:
            out[stage] = (percentile(values, 50), percentile(values, 95),
                          len(values))
    return out


def format_table(summary):
    lines = [f"  {'stage':<14}{'p50 ms':>9}{'p95 ms':>9}{'n':>4}"]
    for stage in STAGES:
        if stage in summary:
            p50, p95, n = summary[stage]
            lines.append(f"  {stage:<14}{p50:>9.0f}{p95:>9.0f}{n:>4}")
    return "\n".join(lines)


def _row_point(client, channel, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for n in client.nodes():
            if n["t"].lower().startswith(channel.lower()):
                return n["x"], n["y"]
        time.sleep(0.25)
    raise AssertionError(f"{client.name}: no row named {channel!r}")


def _join_once(client, channel):
    x, y = _row_point(client, channel)
    # A dwell before the click, as a real pointer has.
    client.hover(x, y, settle=0.6)
    client.ev("window.__joinMarks.arm()")
    client.tap(x, y)
    deadline = time.time() + ARRIVAL_TIMEOUT
    while time.time() < deadline:
        marks = json.loads(client.ev(
            "JSON.stringify(window.__joinMarks.read())") or "{}")
        if "firstSamples" in marks:
            return relative(marks)
        time.sleep(0.2)
    raise AssertionError(f"{client.name}: no remote audio within "
                         f"{ARRIVAL_TIMEOUT}s: {marks}")


def _impair(profile):
    e2e_netem.ensure_image()
    if profile in WAN_PROFILES:
        return e2e_netem.apply_args(WAN_PROFILES[profile])
    return e2e_netem.apply(profile)


def join_time(a, b, room_id, channel=L.VOICE_CHANNEL):
    runs_wanted = int(os.environ.get("JOIN_RUNS", "6"))
    profile = os.environ.get("JOIN_NETEM", "clean")
    if profile == "clean":
        return _join_time(a, b, room_id, channel, runs_wanted)
    print(f"  profile {profile}: {_impair(profile)}")
    try:
        _join_time(a, b, room_id, channel, runs_wanted)
    finally:
        e2e_netem.clear()


def _join_time(a, b, room_id, channel, runs_wanted):
    with e2e_audio.installed(a, extra=e2e_join_probe_js.PROBE), \
            e2e_audio.installed(b):
        _measure(a, b, room_id, channel, runs_wanted)


def _measure(a, b, room_id, channel, runs_wanted):
    b.click(channel)
    b.wait_for(L.IN_CALL)
    participants_with_mics(room_id, expected=1)
    runs = []
    for i in range(runs_wanted):
        runs.append(_join_once(a, channel))
        done = runs[-1]
        print(f"  run {i + 1}: first audio {done['firstSamples']:.0f} ms "
              f"(ice {done.get('ice', float('nan')):.0f})")
        _tap_label(a, L.LEAVE_CALL, settle=3)
        participants_with_mics(room_id, expected=1, timeout=15)
    _tap_label(b, L.LEAVE_CALL, settle=3)
    warm = runs[1:]
    print(f"\n  all {len(runs)} joins\n{format_table(summarize(runs))}")
    print(f"\n  warm joins only ({len(warm)})\n{format_table(summarize(warm))}")
    print("  JOINTIME_JSON " + json.dumps(runs))
    p50 = percentile([r["firstSamples"] for r in runs], 50)
    print(f"  p50 click to first remote audio: {p50:.0f} ms "
          f"(target {TARGET_P50_MS})")
