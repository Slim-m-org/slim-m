# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Refuses to seed anywhere the caller has not explicitly named and confirmed.

A seeding run creates accounts, a channel, and hundreds of messages. Pointed
at the wrong deployment by accident, that is not a bug to fix, it is real
conversation history sitting next to fake noise forever. So there is no
default base URL, `--confirm` is required before anything is written, and the
one deployment this project's own notes document as real and populated by
hand needs a second, more deliberate flag on top of that.
"""
import urllib.parse

# The domain the live instance sits on, so any host under it counts as live.
PRODUCTION_DOMAIN = "npc-server.top"


class GuardError(Exception):
    """A refusal to run, with the reason a person should see, not a traceback."""


def resolve_base_url(explicit, env_value):
    """The target URL, with no default: a flag or the env var must name it."""
    raw = explicit or env_value
    if not raw:
        raise GuardError(
            "no target given: pass --base-url or set SLIM_SEED_BASE_URL; "
            "there is no default, on purpose")
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise GuardError(f"not a usable http(s) URL: {raw!r}")
    return raw.rstrip("/")


def check_confirmed(confirmed, base_url):
    """Refuses to write without an explicit, un-defaultable --confirm."""
    if not confirmed:
        raise GuardError(
            f"refusing to write to {base_url} without --confirm; this "
            "creates accounts, a channel, and a lot of messages")


def is_known_production(base_url):
    """Whether the URL's host is the live deployment's domain or under it."""
    hostname = urllib.parse.urlparse(base_url).hostname or ""
    return hostname == PRODUCTION_DOMAIN or hostname.endswith(f".{PRODUCTION_DOMAIN}")


def check_not_accidental_production(base_url, force_production):
    """A second, harder gate for the one deployment known to hold real data."""
    if is_known_production(base_url) and not force_production:
        hostname = urllib.parse.urlparse(base_url).hostname
        raise GuardError(
            f"{hostname} is the documented live deployment; pass "
            "--i-know-this-is-production as well as --confirm to seed it "
            "anyway, or point this at a disposable deployment instead")


def guard(explicit_url, env_value, confirmed, force_production):
    """Runs all three checks, in the order that gives the clearest refusal."""
    base_url = resolve_base_url(explicit_url, env_value)
    check_confirmed(confirmed, base_url)
    check_not_accidental_production(base_url, force_production)
    return base_url
