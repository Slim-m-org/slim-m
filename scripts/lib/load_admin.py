# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The disposable load server's owner account: claim it, and read /metrics as it.

The first account registered on a fresh deployment owns it, and /metrics needs
MANAGE_SERVER, so load-run.sh claims the deployment itself and hands the token
to k6 rather than letting a scenario's first virtual user do it.
"""
import json
import os
import sys
import urllib.request

import load_target
import seed_guard

USERNAME = "loadadmin"


def _call(base, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{base}{path}", data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def claim(base, password):
    """Registers the owner and returns its access token."""
    raw = _call(base, "/auth/register", {
        "username": USERNAME, "display_name": "Load admin",
        "password": password, "device_name": "load-run"})
    return json.loads(raw)["access_token"]


def metrics(base, password, out_path):
    """Signs in again (an old token may have expired) and saves /metrics."""
    raw = _call(base, "/auth/login", {
        "username": USERNAME, "password": password, "device_name": "load-run"})
    token = json.loads(raw)["access_token"]
    with open(out_path, "wb") as handle:
        handle.write(_call(base, "/metrics", token=token))


def main(argv, environ=os.environ):
    if len(argv) < 3 or argv[1] not in ("claim", "metrics"):
        print("usage: load_admin.py claim <url> | metrics <url> <out>", file=sys.stderr)
        return 2
    password = environ.get("LOAD_ADMIN_PASSWORD", "")
    try:
        base = load_target.check(argv[2])
        if argv[1] == "claim":
            print(claim(base, password))
        else:
            metrics(base, password, argv[3])
    except seed_guard.GuardError as exc:
        print(f"refusing: {exc}", file=sys.stderr)
        return 1
    except (OSError, KeyError, ValueError) as exc:
        print(f"load_admin failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
