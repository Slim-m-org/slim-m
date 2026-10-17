# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Refuse to run the Playwright suite against anything but a local throwaway stack.

The suite registers nothing itself, but it signs in and writes messages, so a
stack.json edited to point at the live deployment would put test traffic in
real conversations. Reuses seed_guard's list of known production hosts.
"""
import json
import sys
import urllib.parse
from pathlib import Path

import seed_guard

LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}


def check_stack(stack):
    """Raise GuardError unless every URL in the stack is local and not production."""
    urls = [stack["api"], stack["web"], stack["livekit"]["http"]]
    for url in urls:
        host = urllib.parse.urlparse(url).hostname or ""
        if seed_guard.is_known_production(url):
            raise seed_guard.GuardError(f"{host} is the live deployment; refusing")
        if host not in LOCAL_HOSTS:
            raise seed_guard.GuardError(f"{url!r} is not a local address; refusing")


def main(argv):
    stack = json.loads(Path(argv[0]).read_text(encoding="utf-8"))
    try:
        check_stack(stack)
    except seed_guard.GuardError as exc:
        sys.exit(f"e2e stack guard: {exc}")


if __name__ == "__main__":
    main(sys.argv[1:])
