# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The voice-health probe reading a real call's getStats.

Needs `voice: two clients in one call` to have run first, and leaves the call up.
"""
import json
import os
import re
import subprocess
import time

from e2e_netem import IMAGE, ensure_image
from e2e_voice_hide_stream import _set_page_visible

LIVEKIT_CONTAINER = os.environ.get("E2E_LK_CONTAINER", "slimm-e2e-lk")
# The jitter buffer is what crosses its 160 ms line; the old 20ms 30ms profile sat at 140-190 ms.
LOSSY = "delay 100ms 200ms loss 20%"
HINT = "connection is unstable"
_LINE = re.compile(r"\[voice-health\][^\"\\]*")


def _flush_log(client):
    """Leaves the foreground for a moment, which makes the app save its debug log.

    It otherwise saves a minute after the first unsaved line, so the minute
    line the probe waits for would reach storage a minute after it was logged.
    """
    _set_page_visible(client, False)
    time.sleep(0.2)
    _set_page_visible(client, True)


def _health_lines(client):
    _flush_log(client)
    raw = client.ev("localStorage.getItem('flutter.debug_log.v1') || ''") or ""
    return _LINE.findall(raw)


def _wait_for_minute_line(client, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        lines = [l for l in _health_lines(client) if "last 60s" in l]
        if lines:
            return lines
        time.sleep(3)
    raise AssertionError(f"{client.name}: no [voice-health] minute line in {timeout}s")


def _netem(command):
    ensure_image()
    done = subprocess.run(
        ["docker", "run", "--rm", "--cap-add", "NET_ADMIN", "--network",
         f"container:{LIVEKIT_CONTAINER}", IMAGE, "sh", "-c", command],
        capture_output=True, text=True)
    if done.returncode:
        raise AssertionError(f"netem failed ({done.returncode}): {done.stderr.strip()[-400:]}")


def minute_line_has_real_numbers(a, b, timeout=240):
    for c in (a, b):
        lines = _wait_for_minute_line(c, timeout)
        print(f"  {c.name}: {lines[-1]}")
        line = lines[-1]
        assert "?" not in line, f"{c.name}: a field was null: {line}"
        sent = re.search(r"sent=(\d+)kbps", line)
        assert sent and int(sent.group(1)) > 0, f"{c.name}: no sent kbps: {line}"
        conceal = re.search(r"conceal=([\d.]+)%", line)
        assert conceal and float(conceal.group(1)) < 2, f"{c.name}: {line}"
        assert re.search(r"rtt=\d+ms", line), f"{c.name}: no rtt: {line}"


def hint_turns_on_under_loss_and_off_after(a, b):
    """Impairs the SFU's egress, so each listener's jitter buffer grows."""
    _netem(f"tc qdisc replace dev eth0 root netem {LOSSY}")
    try:
        started = time.time()
        for c in (a, b):
            c.wait_for(HINT, timeout=90)
            print(f"  {c.name}: hint after {time.time() - started:.0f}s")
            c.shot("voice-health-hint")
            print(f"  {c.name}: the tile hint showed under {LOSSY}")
    finally:
        _netem("tc qdisc del dev eth0 root 2>/dev/null; true")
    for c in (a, b):
        deadline = time.time() + 90
        while c.find(HINT) and time.time() < deadline:
            time.sleep(0.25)
        assert c.find(HINT) is None, f"{c.name}: the hint never cleared"
    print("  the hint cleared once the link was clean")
