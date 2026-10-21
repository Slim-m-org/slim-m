# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Everything the desktop voice scenario needs from the machine, cleaned up after.

A PipeWire null sink plus a remapped virtual source stand in for a microphone, a second sink swallows playback, and a nested `kwin_wayland --virtual` hosts the window.
The owner's default devices, display and files are never touched, and every module and process started here is removed again.
"""
import contextlib
import json
import os
import shutil
import signal
import subprocess
import tempfile
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
            with contextlib.suppress(subprocess.CalledProcessError):
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
            _stop_group(feeder, 10)
        for module in reversed(modules):
            with contextlib.suppress(subprocess.CalledProcessError):
                _pactl("unload-module", module)


def _stop_group(proc, grace):
    """Ends the process group: SIGTERM, then SIGKILL if it outlives `grace` seconds."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)


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


def recording_from_mic(outputs, sources, pids):
    """Whether a recording stream on MIC belongs to one of `pids` (or names no process)."""
    names = {s["index"]: s["name"] for s in sources}
    for out in outputs:
        if names.get(out.get("source")) != MIC:
            continue
        owner = out.get("properties", {}).get("application.process.id")
        if owner is None or int(owner) in pids:
            return True
    return False


def app_captures_mic(pids):
    """Asks PipeWire whether the app is recording from the virtual microphone."""
    outputs = json.loads(_pactl("-f", "json", "list", "source-outputs"))
    sources = json.loads(_pactl("-f", "json", "list", "sources"))
    return recording_from_mic(outputs, sources, set(pids))


def default_devices():
    """The owner's default sink and source, to prove they did not change."""
    text = _pactl("info")
    return [line for line in text.splitlines() if line.startswith("Default ")]


def _socket_path():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), SOCKET)


def kwin_env(base, private):
    """The nested compositor's environment: its own config, data, cache and state, never the owner's."""
    env = {k: v for k, v in base.items() if k not in ("WAYLAND_DISPLAY", "DISPLAY")}
    for var, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                     ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")):
        env[var] = os.path.join(private, sub)
        os.makedirs(env[var], exist_ok=True)
    return env


def kwin_command():
    """kwin on a session bus of its own, so it cannot claim org.kde.KWin on the owner's."""
    return ["dbus-run-session", "--", "kwin_wayland", "--virtual", "--socket", SOCKET,
            "--no-lockscreen", "--width", "1280", "--height", "800"]


def _socket_answers(path):
    """Whether something is listening on the socket; a leftover file from a dead compositor is not."""
    import socket
    with socket.socket(socket.AF_UNIX) as probe:
        probe.settimeout(1)
        try:
            probe.connect(path)
        except OSError:
            return False
    return True


def _log_tail(log, lines=15):
    with contextlib.suppress(OSError), open(log, "r", errors="replace") as fh:
        return "".join(fh.readlines()[-lines:])
    return ""


def _await_socket(proc, log, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise AssertionError(f"the nested compositor exited ({proc.returncode}):\n{_log_tail(log)}")
        if os.path.exists(_socket_path()) and _socket_answers(_socket_path()):
            return
        time.sleep(0.3)
    raise AssertionError(f"the nested compositor never opened {_socket_path()}:\n{_log_tail(log)}")


@contextlib.contextmanager
def nested_compositor(log):
    """The `wayland-test` socket, started here unless something already answers on it."""
    proc, private = None, None
    if not _socket_answers(_socket_path()):
        with contextlib.suppress(FileNotFoundError):
            os.remove(_socket_path())
        private = tempfile.mkdtemp(prefix="slimm-kwin-")
        with open(log, "wb") as out:
            proc = subprocess.Popen(
                kwin_command(), env=kwin_env(os.environ, private), stdout=out, stderr=out,
                stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        if proc is not None:
            _await_socket(proc, log)
        yield _socket_path()
    finally:
        if proc is not None:
            _stop_group(proc, 15)
        if private is not None:
            shutil.rmtree(private, ignore_errors=True)


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
        parts = {p.partition("=")[0]: p.partition("=")[2] for p in line.split() if "=" in p}
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
    return any(link == mine or link.startswith(mine + os.sep) for link in links)


def assert_isolated(pids):
    """Fails unless at least one app process was found and none holds the owner's data."""
    assert pids, "no app process was found, so the owner-data check proved nothing"
    for pid in pids:
        assert not touches_owner_data(pid), f"pid {pid} holds the owner's app data"


def _comm(pid):
    try:
        with open(f"/proc/{pid}/comm") as fh:
            return fh.read().strip()
    except OSError:
        return ""


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
        self.out = None

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
        return [p for p in _marked(os.path.join(self.root, "data")) if _comm(p) == "slimm_app"]

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
        try:
            if self.proc is not None:
                _stop_group(self.proc, 15)
        finally:
            for pid in _marked(marker):
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGTERM)
            if self.out is not None:
                self.out.close()
