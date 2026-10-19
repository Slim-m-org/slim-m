# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Network impairment on the e2e SFU without host root.

`tc netem` runs in a sidecar that shares the LiveKit container's network
namespace, so it shapes what the SFU sends to every listener (the downlink,
which is the path a listener's jitter buffer and concealment see).
"""
import subprocess

IMAGE = "slimm-netem:local"
DOCKERFILE = "FROM alpine:latest\nRUN apk add --no-cache iproute2\n"
LIVEKIT_CONTAINER = "slimm-e2e-lk"
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


def apply(profile, container=LIVEKIT_CONTAINER):
    """Impair the SFU's egress per `profile`; returns the qdisc as tc reports it."""
    args = PROFILES[profile]
    if args is None:
        return clear(container)
    _tc(f"tc qdisc replace dev {DEVICE} root netem {args}", container)
    return _tc(f"tc qdisc show dev {DEVICE}", container).strip()


def clear(container=LIVEKIT_CONTAINER):
    _tc(f"tc qdisc del dev {DEVICE} root 2>/dev/null; tc qdisc show dev {DEVICE}",
        container)
    return "clean"
