# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Everything the desktop voice scenario needs from the machine, cleaned up after.

A PipeWire null sink plus a remapped virtual source stand in for a microphone
(a feeder loops a WAV into the sink), a second null sink swallows the app's
playback, and a nested `kwin_wayland --virtual` gives the Flutter window
somewhere to be. The owner's default devices, display and files are never
touched: the app reads PULSE_SOURCE / PULSE_SINK for itself only, runs with
its own XDG directories, and every module and process started here is
removed again.
"""
import contextlib
import json
import os
import shutil
import signal
import subprocess
import time

SINK = "slimm_vq_sink"
MIC = "slimm_vq_mic"
OUT = "slimm_vq_out"
SOCKET = "wayland-test"
APP_ID = "top.npcserver.slimm"


def _pactl(*args):
    return subprocess.run(["pactl", *args], check=True, capture_output=True,
                          text=True).stdout.strip()


def sweep_stale():
    """Unloads modules a crashed earlier run left behind; they all carry our names."""
    for line in _pactl("list", "short", "modules").splitlines():
        if any(name in line for name in (SINK, MIC, OUT)):
            _pactl("unload-module", line.split()[0])


@contextlib.contextmanager
def virtual_mic(wav):
    """A source named MIC that plays `wav` on a loop; yields the playback process."""
    sweep_stale()
    modules, feeder = [], None
    try:
        modules.append(_pactl("load-module", "module-null-sink", f"sink_name={SINK}",
                              "channel_map=mono",
                              f"sink_properties=device.description={SINK}"))
        modules.append(_pactl("load-module", "module-remap-source",
                              f"master={SINK}.monitor", f"source_name={MIC}",
                              "channel_map=mono",
                              f"source_properties=device.description={MIC}"))
        modules.append(_pactl("load-module", "module-null-sink", f"sink_name={OUT}",
                              f"sink_properties=device.description={OUT}"))
        feeder = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-re", "-stream_loop", "-1", "-i", wav,
             "-f", "pulse", "-ac", "1", "-ar", "48000", "-device", SINK, "slimm_vq_feed"],
            stdin=subprocess.DEVNULL, start_new_session=True)
        full_volume()
        yield feeder
    finally:
        if feeder is not None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(feeder.pid, signal.SIGTERM)
            feeder.wait(timeout=10)
        for module in reversed(modules):
            with contextlib.suppress(subprocess.CalledProcessError):
                _pactl("unload-module", module)


def full_volume():
    """Restores 100% on the feeder's stream and the mic: a remembered 0% would play silence."""
    deadline = time.time() + 10
    while time.time() < deadline:
        for block in _pactl("list", "sink-inputs").split("Sink Input #")[1:]:
            if "slimm_vq_feed" in block:
                ident = block.split()[0]
                _pactl("set-sink-input-mute", ident, "0")
                _pactl("set-sink-input-volume", ident, "100%")
                for kind in ("source",):
                    _pactl(f"set-{kind}-mute", MIC, "0")
                    _pactl(f"set-{kind}-volume", MIC, "100%")
                return
        time.sleep(0.3)
    raise AssertionError("the microphone feeder never appeared as a playback stream")


def default_devices():
    """The owner's default sink and source, to prove they did not change."""
    text = _pactl("info")
    return [line for line in text.splitlines() if line.startswith("Default ")]


def _socket_path():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), SOCKET)


@contextlib.contextmanager
def nested_compositor(log):
    """The `wayland-test` socket, started here unless it already answers."""
    proc = None
    if not os.path.exists(_socket_path()):
        env = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "DISPLAY")}
        with open(log, "wb") as out:
            proc = subprocess.Popen(
                ["kwin_wayland", "--virtual", "--socket", SOCKET, "--no-lockscreen",
                 "--width", "1280", "--height", "800"],
                env=env, stdout=out, stderr=out, stdin=subprocess.DEVNULL,
                start_new_session=True)
        deadline = time.time() + 30
        while not os.path.exists(_socket_path()) and time.time() < deadline:
            time.sleep(0.3)
    try:
        yield _socket_path()
    finally:
        if proc is not None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=15)


def seed_profile(root, server, tokens, prefs):
    """An empty per-run XDG tree holding a signed-in session and the arm's settings."""
    shutil.rmtree(root, ignore_errors=True)
    for sub in ("data", "config", "cache", "state"):
        os.makedirs(os.path.join(root, sub))
    folder = os.path.join(root, "data", APP_ID)
    os.makedirs(folder, mode=0o700)
    with open(os.path.join(folder, "slimm_secrets.json"), "w") as fh:
        json.dump({"server_url": server, "session_token_pair": json.dumps(tokens)}, fh)
    os.chmod(os.path.join(folder, "slimm_secrets.json"), 0o600)
    stored = {"flutter.slimm.has_launched_before": True}
    stored.update({f"flutter.{key}": value for key, value in prefs.items()})
    with open(os.path.join(folder, "shared_preferences.json"), "w") as fh:
        json.dump(stored, fh)
    return root


def gate_summary(lines):
    """Share of gate readings that were open, and that rnnoise processed."""
    total = open_ = strong = 0
    for line in lines:
        parts = dict(p.split("=") for p in line.split() if "=" in p)
        total += int(parts["readings"])
        open_ += int(parts["open"])
        strong += int(parts["strong"])
    return {"readings": total,
            "open": round(open_ / total, 3) if total else None,
            "strong": round(strong / total, 3) if total else None}


def _owner_data_dir():
    return os.path.realpath(os.path.expanduser(f"~/.local/share/{APP_ID}"))


def touches_owner_data(pid):
    """True when the process holds a file under the owner's real app data directory."""
    mine = _owner_data_dir()
    try:
        links = [os.path.realpath(os.path.join(f"/proc/{pid}/fd", fd))
                 for fd in os.listdir(f"/proc/{pid}/fd")]
    except OSError:
        return False
    return any(link.startswith(mine) for link in links)


def _marked(marker):
    pids = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == os.getpid():
            continue
        try:
            with open(f"/proc/{entry}/environ", "rb") as fh:
                if marker.encode() in fh.read():
                    pids.append(int(entry))
        except OSError:
            continue
    return pids


class Desktop:
    """One run of the Linux client in the nested compositor, inside its own session bus."""

    def __init__(self, bundle, root, channel, log):
        self.bundle, self.root, self.channel, self.log = bundle, root, channel, log
        self.proc = None

    def start(self, compositor):
        env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY",)}
        env.update(WAYLAND_DISPLAY=os.path.basename(compositor), GDK_BACKEND="wayland",
                   XDG_DATA_HOME=os.path.join(self.root, "data"),
                   XDG_CONFIG_HOME=os.path.join(self.root, "config"),
                   XDG_CACHE_HOME=os.path.join(self.root, "cache"),
                   XDG_STATE_HOME=os.path.join(self.root, "state"),
                   PULSE_SOURCE=MIC, PULSE_SINK=OUT)
        self.out = open(self.log, "wb")
        self.proc = subprocess.Popen(
            ["dbus-run-session", "--", os.path.join(self.bundle, "slimm_app"),
             f"--voice-harness-channel={self.channel}"],
            env=env, stdout=self.out, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, start_new_session=True)

    def app_pids(self):
        return [p for p in _marked(os.path.join(self.root, "data"))
                if open(f"/proc/{p}/comm").read().strip() == "slimm_app"]

    def wait_for(self, text, timeout, fail_on=None):
        """Waits for [text] in the app's log; [fail_on] in it raises at once with its line."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise AssertionError(f"the desktop app exited ({self.proc.returncode})")
            with open(self.log, "r", errors="replace") as fh:
                content = fh.read()
            if fail_on and fail_on in content:
                line = next(ln for ln in content.splitlines() if fail_on in ln)
                raise AssertionError(f"the desktop app reported {line.strip()!r}")
            if text in content:
                return
            time.sleep(0.5)
        raise AssertionError(f"the desktop app never printed {text!r}")

    def gate_lines(self):
        with open(self.log, "r", errors="replace") as fh:
            return [ln for ln in fh.read().splitlines() if "SLIMM_HARNESS gate" in ln]

    def stop(self):
        marker = os.path.join(self.root, "data")
        if self.proc is not None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(self.proc.pid, signal.SIGTERM)
            with contextlib.suppress(subprocess.TimeoutExpired):
                self.proc.wait(timeout=15)
            with contextlib.suppress(ProcessLookupError):
                os.killpg(self.proc.pid, signal.SIGKILL)
        for pid in _marked(marker):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGTERM)
        self.out.close()
