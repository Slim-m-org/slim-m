# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Network impairment on the e2e SFU without host root.

`tc netem` runs in a sidecar that shares the LiveKit container's network
namespace, so it shapes what the SFU sends to every listener (the downlink,
which is the path a listener's jitter buffer and concealment see).
"""
import os
import subprocess
import time

IMAGE = "slimm-netem:local"
DOCKERFILE = "FROM alpine:latest\nRUN apk add --no-cache iproute2\n"
# The stack names its SFU from the same variable, so a second stack is shaped, not the first.
LIVEKIT_CONTAINER = os.environ.get("E2E_LK_CONTAINER", "slimm-e2e-lk")
DEVICE = "eth0"

# name -> tc netem arguments; None leaves the link alone.
PROFILES = {
    "clean": None,
    "loss2": "loss 2%",
    "loss5-jitter30": "delay 20ms 30ms loss 5%",
    "burst": "loss gemodel 1% 10% 70% 0.1%",
    "delay150-jitter50": "delay 150ms 50ms",
}


def _docker(*args, stdin=None):
    return subprocess.run(["docker", *args], input=stdin, check=True,
                          capture_output=True, text=True).stdout


def ensure_image():
    have = subprocess.run(["docker", "image", "inspect", IMAGE],
                          capture_output=True).returncode == 0
    if not have:
        _docker("build", "-q", "-t", IMAGE, "-", stdin=DOCKERFILE)


def _tc(command, container=LIVEKIT_CONTAINER):
    return _docker("run", "--rm", "--cap-add", "NET_ADMIN",
                   "--network", f"container:{container}", IMAGE,
                   "sh", "-c", command)


# A full outage of what the SFU sends, kept out of PROFILES so a sweep does not run it.
CUT = "loss 100%"


def apply(profile, container=LIVEKIT_CONTAINER):
    """Impair the SFU's egress per `profile`; returns the qdisc as tc reports it."""
    args = PROFILES[profile]
    if args is None:
        return clear(container)
    return apply_args(args, container)


def apply_args(args, container=LIVEKIT_CONTAINER):
    _tc(f"tc qdisc replace dev {DEVICE} root netem {args}", container)
    return _tc(f"tc qdisc show dev {DEVICE}", container).strip()


def clear(container=LIVEKIT_CONTAINER):
    _tc(f"tc qdisc del dev {DEVICE} root 2>/dev/null; tc qdisc show dev {DEVICE}",
        container)
    return "clean"


def _stamped(command, container):
    """Runs `command` in the sidecar; returns the host epoch ms at the midpoint of the call.

    The sidecar's busybox date has no sub-second field, so the call's own
    duration (a few hundred ms of container start) is the uncertainty.
    """
    began = time.time()
    _tc(command, container)
    return (began + time.time()) / 2 * 1000.0


def cut(container=LIVEKIT_CONTAINER):
    """Starts a full outage; returns the epoch ms it took hold, give or take the call time."""
    return _stamped(f"tc qdisc replace dev {DEVICE} root netem {CUT}", container)


def restore(container=LIVEKIT_CONTAINER):
    """Ends the outage; returns the epoch ms the link came back, give or take the call time."""
    return _stamped(f"tc qdisc del dev {DEVICE} root", container)
