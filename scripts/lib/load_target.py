# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Refuses any load target that is not this machine.

Load is indistinguishable from abuse, so unlike the seed guard there is no
override flag: the only accepted hosts are loopback names and addresses.
"""
import ipaddress
import sys
import urllib.parse

import seed_guard

LOOPBACK_NAMES = frozenset({"localhost"})


def _is_loopback(hostname):
    if hostname in LOOPBACK_NAMES:
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def check(raw_url):
    """The URL without a trailing slash, or a GuardError saying why not."""
    base_url = seed_guard.resolve_base_url(raw_url, None)
    if seed_guard.is_known_production(base_url):
        raise seed_guard.GuardError(
            f"{base_url} is the live deployment; load tests never run against it")
    hostname = urllib.parse.urlparse(base_url).hostname
    if not _is_loopback(hostname):
        raise seed_guard.GuardError(
            f"{hostname} is not a loopback host; load tests only run against "
            "a disposable local server")
    return base_url


def main(argv):
    if len(argv) != 2:
        print("usage: load_target.py <base-url>", file=sys.stderr)
        return 2
    try:
        print(check(argv[1]))
    except seed_guard.GuardError as exc:
        print(f"refusing: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
