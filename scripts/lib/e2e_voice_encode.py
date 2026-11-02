# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What the Linux client really encodes for a screen share and a camera, read back from its own sender stats.

The release client built with `--dart-define=SLIMM_VOICE_HARNESS=true` joins a call, starts a share or the camera from launch flags and prints one line per simulcast layer per sample.
A share runs on Xwayland inside a nested compositor of a known size, so the captured screen has a size the run chose; the camera is the box's own webcam.
Opt in with E2E_ONLY="encode readback"; E2E_DESKTOP_BUNDLE points at the build and E2E_ENCODE_CASES lists cases such as `share:3840x2160:1080p30` or `camera:high`; `share:1920x1080:1080p30:restart` also stops the share and starts it again.
"""
import glob
import json
import os
import re
import time
import wave

import desktop_audio as da
import e2e_labels as L
import e2e_voice_desktop as vd
import e2e_xp as xp
from private_pulse import private_server

CASES = "share:1920x1080:1080p30,share:3840x2160:1080p30,share:3440x1440:1080p30,camera:balanced,camera:high"
SETTLE_SECONDS = int(os.environ.get("E2E_ENCODE_SECONDS", "25"))
LINE = re.compile(r"SLIMM_HARNESS encode source=(\w+) rid=(\S+) w=(\S+) h=(\S+) fps=(\S+) bps=(\S+) target=(\S+) limit=(\S+)")


def parse_case(text):
    """`share:WxH:tier` or `camera:quality` as the screen size, the launch flag and a label."""
    kind, _, rest = text.partition(":")
    if kind == "camera":
        return {"label": text, "size": (1280, 800), "flags": [f"--voice-harness-camera={rest}"], "source": "camera"}
    size, _, tier = rest.partition(":")
    tier, _, mode = tier.partition(":")
    width, height = (int(v) for v in size.split("x"))
    flags = [f"--voice-harness-share={tier}"] + (["--voice-harness-share-restart"] if mode == "restart" else [])
    return {"label": text, "size": (width, height), "flags": flags, "source": "screenShare"}


def layers(lines, source):
    """The last reading of every layer of [source] in the app's output."""
    last = {}
    for line in lines:
        found = LINE.search(line)
        if found and found.group(1) == source:
            last[found.group(2)] = {"rid": found.group(2), "width": found.group(3), "height": found.group(4),
                                    "fps": found.group(5), "bps": found.group(6), "limit": found.group(8)}
    return [last[k] for k in sorted(last)]


def _x11_sockets():
    return set(glob.glob("/tmp/.X11-unix/X*"))


def _display_after(started, log, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        fresh = [p for p in _x11_sockets() if os.stat(p).st_mtime >= started]
        if fresh:
            return ":" + os.path.basename(min(fresh))[1:]
        time.sleep(0.5)
    raise AssertionError(f"the nested compositor opened no X display:\n{da._log_tail(log)}")


def _await_displays_gone(baseline, timeout=20):
    """The next compositor reuses the display number, so the last one's socket must be gone first."""
    deadline = time.time() + timeout
    while time.time() < deadline and _x11_sockets() - baseline:
        time.sleep(0.5)


def _run_case(case, ctx):
    width, height = case["size"]
    slug = re.sub(r"\W+", "-", case["label"])
    started = time.time() - 1
    log = os.path.join(ctx["directory"], f"kwin-{slug}.log")
    tokens = vd._tokens(ctx["server"], ctx["secret"])
    with da.nested_compositor(log, width, height, xwayland=True) as compositor:
        display = _display_after(started, log)
        root = da.seed_profile(os.path.join(ctx["directory"], "xdg-encode"), ctx["server"], tokens, {})
        app_log = os.path.join(ctx["directory"], f"app-{slug}.log")
        app = da.Desktop(ctx["bundle"], root, ctx["channel"], app_log, extra_args=case["flags"])
        try:
            app.start(compositor, x11_display=display)
            app.wait_for("SLIMM_HARNESS joined", 150, fail_on=vd.JOIN_FAILED)
            time.sleep(SETTLE_SECONDS)
            with open(app_log, "r", errors="replace") as fh:
                lines = fh.read().splitlines()
            print("\n".join(ln for ln in lines if "SLIMM_HARNESS log" in ln), flush=True)
        finally:
            app.stop()
    _await_displays_gone(ctx["displays"])
    restarted = any("SLIMM_HARNESS share restarted" in ln for ln in lines)
    return {"case": case["label"], "screen": f"{width}x{height}", "layers": layers(lines, case["source"]), "restarted": restarted}


def an_encode_matches_what_was_asked(server, secret, admin_api):
    bundle = os.path.abspath(os.environ.get("E2E_DESKTOP_BUNDLE") or vd.BUNDLE)
    assert os.path.exists(os.path.join(bundle, "slimm_app")), f"no desktop build at {bundle}"
    cases = [parse_case(c) for c in os.environ.get("E2E_ENCODE_CASES", CASES).split(",") if c]
    xp.e2e_browsers.register(server, admin_api, vd.USER, secret)
    channel = admin_api.channel_named(L.VOICE_CHANNEL)["id"]
    directory = xp.out_dir("encode-readback")
    ctx = {"server": server, "secret": secret, "directory": directory, "bundle": bundle, "channel": channel,
           "displays": _x11_sockets()}
    results = []
    silence = os.path.join(directory, "silence.wav")
    with wave.open(silence, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(48000)
        fh.writeframes(bytes(2 * 48000 * 60))
    with private_server(), da.virtual_mic(silence):
        da._pactl("load-module", "module-null-sink", "sink_name=slimm_vq_room")
        for case in cases:
            result = _run_case(case, ctx)
            print(json.dumps(result), flush=True)
            results.append(result)
    with open(os.path.join(directory, "encode-readback.json"), "w") as fh:
        json.dump(results, fh, indent=1)
    assert all(r["layers"] for r in results), "a case printed no sender stats"
    return results


def run_if_selected(server, secret, admin_api):
    if "encode readback" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='encode readback' to run it")
        return
    an_encode_matches_what_was_asked(server, secret, admin_api)
