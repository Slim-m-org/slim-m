# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A PipeWire and PulseAudio server of its own, so a harness never plays into the owner's speakers.

The owner's session routes streams by application name into real sinks and remembers volumes, so a test client's playback would be heard on the headset and measured against rules nobody wrote down.
This starts pipewire, wireplumber and pipewire-pulse under a private runtime directory and session bus, with none of the owner's configuration, and points PULSE_SERVER at it for everything started inside the block.
"""
import contextlib
import os
import shutil
import subprocess
import tempfile
import time

from desktop_audio import _stop_group

START = "pipewire & sleep 1; wireplumber & sleep 2; pipewire-pulse & wait"


def _private_env(root):
    env = {k: v for k, v in os.environ.items() if k not in ("PULSE_SERVER", "PULSE_SINK", "PULSE_SOURCE")}
    env.update(XDG_RUNTIME_DIR=root, PIPEWIRE_RUNTIME_DIR=root,
               PULSE_RUNTIME_PATH=os.path.join(root, "pulse"))
    for var, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                     ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")):
        env[var] = os.path.join(root, sub)
        os.makedirs(env[var], exist_ok=True)
    return env


def _await_server(server, proc, timeout=30):
    deadline = time.time() + timeout
    env = {**os.environ, "PULSE_SERVER": server}
    while time.time() < deadline:
        if proc.poll() is not None:
            raise AssertionError(f"the private audio server exited ({proc.returncode})")
        if subprocess.run(["pactl", "info"], env=env, capture_output=True).returncode == 0:
            return
        time.sleep(0.3)
    raise AssertionError("the private audio server never answered")


@contextlib.contextmanager
def private_server():
    """Yields the PULSE_SERVER string; it is also set in this process's environment meanwhile."""
    root = tempfile.mkdtemp(prefix="slimm-pw-", dir=os.environ.get("TMPDIR"))
    os.chmod(root, 0o700)
    server = f"unix:{os.path.join(root, 'pulse', 'native')}"
    before = os.environ.get("PULSE_SERVER")
    proc = subprocess.Popen(["dbus-run-session", "--", "bash", "-c", START],
                            env=_private_env(root), stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    try:
        _await_server(server, proc)
        os.environ["PULSE_SERVER"] = server
        yield server
    finally:
        if before is None:
            os.environ.pop("PULSE_SERVER", None)
        else:
            os.environ["PULSE_SERVER"] = before
        _stop_group(proc, 10)
        shutil.rmtree(root, ignore_errors=True)
