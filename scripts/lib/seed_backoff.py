# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Retrying a write past a 429, without crashing the run or losing the action.

`Class::Write` (crates/slimm-server/src/ratelimit.rs) is a 30-request burst
refilling at 5/s, keyed per authenticated user. Ten accounts acting in
parallel each have their own bucket, but a single account moving fast enough
- a burst of consecutive messages, say - can still outrun its own refill.
The answer is jittered exponential backoff on the caller's side, not a
smaller burst on the server's: a 429 here is expected traffic shaping, not a
failure worth aborting the run over.
"""
import random
import time
import urllib.error


def is_rate_limited(exc):
    """True for the one error this module exists to absorb."""
    return isinstance(exc, urllib.error.HTTPError) and exc.code == 429


def call_with_backoff(action, *, is_retryable=is_rate_limited, max_attempts=8,
                       base_delay=1.0, max_delay=20.0, sleep=time.sleep,
                       rng=random):
    """Calls `action()`, retrying on a retryable exception with backoff.

    Re-raises the last exception once `max_attempts` is spent, or immediately
    for anything `is_retryable` says is not worth retrying at all - a 400 is
    a bug in what this script sent, and retrying it would only ever fail the
    same way `max_attempts` times slower.
    """
    attempt = 0
    while True:
        try:
            return action()
        except Exception as exc:
            if not is_retryable(exc) or attempt >= max_attempts - 1:
                raise
            delay = min(max_delay, base_delay * (2 ** attempt))
            sleep(delay * (0.5 + rng.random()))
            attempt += 1


def describe_error(exc):
    """A one-line reason, reading the body of an HTTPError when there is one."""
    if isinstance(exc, urllib.error.HTTPError):
        try:
            detail = exc.read().decode(errors="replace")[:300]
        # the body is a bonus, not the point
        except Exception:  # noqa: BLE001
            detail = ""
        return f"HTTP {exc.code}{': ' + detail if detail else ''}"
    return str(exc)
