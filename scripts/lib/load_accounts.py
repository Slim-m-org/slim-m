# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Getting N authenticated sessions without paying for them every run.

Registration and login share one address-keyed bucket that allows five in a
burst and then one every six seconds, so standing up a hundred accounts costs
about ten minutes. That is worth measuring once and worth never measuring
again: a run that spends ten minutes before it starts is a run nobody
iterates on.

So both halves of the token pair are cached, keyed by deployment. Access
tokens are short-lived by design, which is why the refresh half matters:
refreshing is charged to its own generous bucket rather than the tight
password one, so a cache written an hour ago still revives instantly while a
fresh login for each account would cost the full ten minutes again.

`seed_accounts` is not reused here for exactly that reason. It returns an
authenticated handle but discards the refresh token, and a refresh token
cannot be recovered from an access token afterwards.
"""
import json
import os
import pathlib
import tempfile
import urllib.error

import e2e_api
import seed_backoff
import seed_content


class AccountSetupError(RuntimeError):
    """Raised when the accounts this run needs cannot be obtained."""


def _cache_path(directory, base_url):
    """The cache file, under a resolved directory and a derived name.

    The directory comes from the command line and the name is built from the
    deployment address rather than taken from it, so neither half can carry a
    traversal out of where the caller asked the file to live.
    """
    safe = "".join(c if c.isalnum() else "-" for c in base_url).strip("-")
    root = pathlib.Path(directory).expanduser().resolve()
    return root / f"loadtest-tokens-{safe}.json"


def _load_cache(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _entry(account):
    """One cache row, from either a live account or an existing row."""
    api = account.get("api")
    return {"username": account["username"],
            "display_name": account["display_name"],
            "token": api.token if api is not None else account.get("token"),
            "refresh": account.get("refresh")}


def _save_cache(path, accounts):
    """Replaces the cache whole, so a kill mid-write cannot cost the tokens.

    mkstemp creates the temp file 0600, so there is no readable window either.
    """
    payload = [_entry(a) for a in accounts]
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def _revive(base_url, entry):
    """The account's session, refreshed when its access token has aged out.

    Access tokens last fifteen minutes and refresh tokens thirty days, so
    within the window this costs one cheap authenticated probe per account
    against that account's own generous bucket. Past it, the refresh is
    charged to an address-keyed bucket allowing ten in a burst and one every
    two seconds, which is why it needs the same backoff every other
    rate-limited call here uses. Without it the hundredth account gives up on
    a 429 and the whole cache is discarded for a fully expired set.
    """
    api = e2e_api.Api(base_url, token=entry["token"])
    try:
        api.me()
        return api, entry.get("refresh")
    except (urllib.error.HTTPError, urllib.error.URLError):
        pass
    if not entry.get("refresh"):
        return None, None
    try:
        got = seed_backoff.call_with_backoff(
            lambda: e2e_api.Api(base_url).call(
                "POST", "/auth/refresh",
                {"refresh_token": entry["refresh"]}),
            max_attempts=10, base_delay=2.0, max_delay=30.0)
    except (urllib.error.HTTPError, urllib.error.URLError):
        return None, None
    api.token = got["access_token"]
    return api, got["refresh_token"]


def _enrol(base_url, index, password, invite_code):
    """Registers one account, or signs in to the one already holding the name.

    Both 400 and 409 fall through to a login attempt. A claimed deployment
    refuses a codeless registration with 400 before it ever looks at the
    username, so an account that already exists reports as 400 rather than
    the 409 the name collision would otherwise produce.
    """
    username, display = seed_content.persona(index, tag="lt")
    api = e2e_api.Api(base_url)
    body = {"username": username, "display_name": display,
            "password": password, "device_name": f"loadtest-{index}"}
    if invite_code:
        body["invite_code"] = invite_code
    try:
        got = seed_backoff.call_with_backoff(
            lambda: api.call("POST", "/auth/register", dict(body)))
    except urllib.error.HTTPError as exc:
        if exc.code not in (400, 409):
            raise
        try:
            got = seed_backoff.call_with_backoff(
                lambda: api.call("POST", "/auth/login",
                                 {"username": username, "password": password,
                                  "device_name": f"loadtest-{index}"}))
        except urllib.error.HTTPError:
            raise exc from None
    api.token = got["access_token"]
    return {"username": username, "display_name": display, "api": api,
            "refresh": got.get("refresh_token"), "reused": False}


def _login(base_url, index, password):
    """Signs in to an account known to exist, skipping the doomed register.

    Enrolment attempts a registration first, and on a claimed deployment that
    always fails while still spending a token from the address-keyed bucket
    that allows one every six seconds. For an account already in the cache
    that attempt is pure waste, and skipping it halves the recovery cost.
    """
    username, display = seed_content.persona(index, tag="lt")
    api = e2e_api.Api(base_url)
    got = seed_backoff.call_with_backoff(
        lambda: api.call("POST", "/auth/login",
                         {"username": username, "password": password,
                          "device_name": f"loadtest-{index}"}),
        max_attempts=10, base_delay=2.0, max_delay=30.0)
    api.token = got["access_token"]
    return {"username": username, "display_name": display, "api": api,
            "refresh": got.get("refresh_token"), "reused": True}


def _mint_invite(api, uses):
    try:
        got = seed_backoff.call_with_backoff(
            lambda: api.call("POST", "/invites", {"max_uses": uses}))
        return got.get("code")
    except (urllib.error.HTTPError, urllib.error.URLError):
        return None


def _enrol_all(base_url, count, password, invite_code):
    accounts = []
    working = invite_code
    for index in range(count):
        try:
            accounts.append(_enrol(base_url, index, password, working))
        except urllib.error.HTTPError as exc:
            raise AccountSetupError(
                f"could not enrol account {index}: "
                f"{seed_backoff.describe_error(exc)}") from exc
        if index == 0 and working is None and count > 1:
            working = _mint_invite(accounts[0]["api"], count - 1)
    return accounts


def obtain(base_url, count, password, invite_code, cache_dir):
    """N authenticated handles, from cache where the cache still revives.

    Returns `(accounts, from_cache)`. A cache that is too small or refuses to
    revive falls back to enrolment and is rewritten, so a wiped server heals
    itself rather than needing the file deleted by hand.

    The cache is rewritten after every account, because refresh rotation is
    single-use: a token already exchanged is spent, and losing the
    replacement strands that account behind a full login. One account that
    cannot revive falls back to a login for itself alone rather than
    condemning the other ninety-nine to the same.
    """
    path = _cache_path(cache_dir, base_url)
    cached = _load_cache(path)
    if cached and len(cached) >= count:
        revived = []
        for index, entry in enumerate(cached[:count]):
            api, refresh = _revive(base_url, entry)
            if api is None:
                try:
                    got = _login(base_url, index, password)
                except urllib.error.HTTPError:
                    revived = []
                    break
                api, refresh = got["api"], got["refresh"]
            revived.append({"username": entry["username"],
                            "display_name": entry["display_name"],
                            "api": api, "refresh": refresh, "reused": True})
            _save_cache(path, revived + cached[len(revived):])
        if len(revived) == count:
            return revived, True

    accounts = _enrol_all(base_url, count, password, invite_code)
    _save_cache(path, accounts)
    return accounts, False
