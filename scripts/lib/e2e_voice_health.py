# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The voice-health probe reading a real call's getStats.

Needs `voice: two clients in one call` to have run first, and leaves the call up.
"""
import os
import re
import subprocess
import time

from e2e_netem import IMAGE, ensure_image
import e2e_labels as L

LIVEKIT_CONTAINER = os.environ.get("E2E_LK_CONTAINER", "slimm-e2e-lk")
# The jitter buffer is what crosses its 160 ms line; the old 20ms 30ms profile sat at 140-190 ms.
LOSSY = "delay 100ms 200ms loss 20%"
HINT = "connection is unstable"
MINUTE_PREFIX = "[voice-health] last 60s"
CONCEAL_LIMIT = 2
# The call stays on screen for a minute before Troubleshooting is opened once.
MINUTE_WAIT = 65


def _minute_line_in(report):
    """The `[voice-health] last 60s` line of a copied call diagnostics block, or None."""
    for line in report.splitlines():
        if line.startswith(MINUTE_PREFIX):
            return line
    return None


def _copied_diagnostics(client):
    """Opens Troubleshooting mid-call, presses Copy call diagnostics and returns the clipboard.

    A healthy minute no longer reaches the debug log, so the copied block is the only place it is kept.
    """
    client.send("Browser.grantPermissions",
                {"permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
    client.click(L.PERSONAL_SETTINGS, settle=3)
    client.click(L.TROUBLESHOOTING_PANE, settle=2)
    client.wheel_until(L.LAST_CALL_AUDIO, L.COPY_CALL_DIAGNOSTICS)
    client.click(L.COPY_CALL_DIAGNOSTICS, settle=1.5)
    got = client.send("Runtime.evaluate", {
        "expression": "navigator.clipboard.readText()",
        "awaitPromise": True, "returnByValue": True})
    client.click(L.BACK_TO_CHANNELS, settle=2)
    return got.get("result", {}).get("result", {}).get("value") or ""


def _wait_for_minute_line(client, timeout, after=None):
    """The latest minute line, once there is one that is not `after`."""
    time.sleep(MINUTE_WAIT)
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = _minute_line_in(_copied_diagnostics(client))
        if line and line != after:
            return line
        time.sleep(15)
    raise AssertionError(f"{client.name}: no [voice-health] minute line in {timeout}s")


def concealed_percent(line):
    found = re.search(r"conceal=([\d.]+)%", line)
    return float(found.group(1)) if found else None


def _quiet_minute(client, line, tries=2):
    """A minute whose concealment is under the limit, re-measuring after a stall.

    Concealment at 0% loss only comes from the listener's own playout starving,
    which a loaded runner does for a stretch (2.7% with accel=1892ms was one such
    minute); a call that is really broken conceals in every minute.
    """
    for attempt in range(tries):
        share = concealed_percent(line)
        assert share is not None, f"{client.name}: no conceal field: {line}"
        if share < CONCEAL_LIMIT:
            return line
        print(f"  {client.name}: minute {attempt + 1} concealed {share}%, measuring the next")
        if attempt + 1 < tries:
            line = _wait_for_minute_line(client, 150, after=line)
    raise AssertionError(f"{client.name}: concealment stayed over {CONCEAL_LIMIT}% for {tries} minutes: {line}")


def _netem(command):
    ensure_image()
    done = subprocess.run(
        ["docker", "run", "--rm", "--cap-add", "NET_ADMIN", "--network",
         f"container:{LIVEKIT_CONTAINER}", IMAGE, "sh", "-c", command],
        capture_output=True, text=True)
    if done.returncode:
        raise AssertionError(f"netem failed ({done.returncode}): {done.stderr.strip()[-400:]}")


def minute_line_has_real_numbers(a, b, timeout=120):
    for c in (a, b):
        line = _wait_for_minute_line(c, timeout)
        print(f"  {c.name}: {line}")
        assert "?" not in line, f"{c.name}: a field was null: {line}"
        sent = re.search(r"sent=(\d+)kbps", line)
        assert sent and int(sent.group(1)) > 0, f"{c.name}: no sent kbps: {line}"
        line = _quiet_minute(c, line)
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
