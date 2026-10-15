# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Registers the seed accounts and the day's channel.

Reuses `e2e_api.Api` for every call rather than a second HTTP client, and
follows `e2e_seed.py`'s own pattern of a first-account-claims-a-fresh-
deployment flow - extended here to also work against an already-claimed one,
via an admin login that mints an invite and creates the channel itself.

Repeat runs reuse the same accounts by default rather than minting a fresh
cohort: `seed-data.py` now defaults `--username-tag` to empty and the
password to a value cached per deployment (`seed_credentials.py`), so a
persona's username is stable across runs and `register_accounts` logs into
it instead of re-registering the moment it already exists.
"""
import urllib.error

import e2e_api
import seed_backoff
import seed_content


class AccountSetupError(Exception):
    """A refusal to continue, with the reason a person should see."""


def obtain_invite_code(base_url, accounts_needed, invite_code, admin_username,
                        admin_password, device_prefix):
    """Returns (code_or_None, admin_api_or_None).

    An explicit code or an admin login (which mints one sized for the whole
    run) is used directly. Otherwise this returns no code at all and leaves
    it to `register_accounts`: whether one turns out to be needed depends on
    whether the deployment is already claimed, which nothing can answer
    ahead of actually trying to register the first account.
    """
    if invite_code:
        return invite_code, None

    if admin_username:
        admin_api = e2e_api.Api(base_url)
        try:
            admin_api.login(admin_username, admin_password,
                             device=f"{device_prefix}-admin")
            admin_api.keep_signed_in(admin_username, admin_password,
                                      f"{device_prefix}-admin")
            minted = admin_api.call("POST", "/invites",
                                     {"max_uses": accounts_needed})
        except urllib.error.HTTPError as exc:
            raise AccountSetupError(
                "could not log in as the given admin account, or mint an "
                f"invite from it: {seed_backoff.describe_error(exc)}") from exc
        return minted["code"], admin_api

    return None, None


def _mint_invite_if_possible(api, uses_needed):
    """Tries to mint a code from the account that just registered.

    The first account may have just claimed a previously unclaimed
    deployment and gained CREATE_INVITE along with it; if not (an open join
    policy, or someone else already claimed it), the remaining accounts can
    still register with no code at all, so a failure here is swallowed
    rather than fatal.
    """
    try:
        minted = seed_backoff.call_with_backoff(
            lambda: api.call("POST", "/invites", {"max_uses": uses_needed}))
        return minted["code"]
    except urllib.error.HTTPError:
        return None


def register_accounts(base_url, count, password, invite_code, device_prefix,
                       username_tag=""):
    """Registers `count` accounts, reusing one already registered under a
    persona's username rather than minting a new one every run.

    Retries past the tight, IP-keyed password bucket rather than firing
    every registration at once. With no code given up front, the first
    account registers with none at all: on a still-unclaimed deployment
    that both succeeds and claims it, at which point it mints a code of its
    own for the rest (see `_mint_invite_if_possible`), the same shape
    `e2e_seed.py` already uses for its two accounts, generalised to N.

    A username already taken (409, or 400 on a claimed invite-only deployment) is logged into instead of treated as a
    failure, using the same `password` this call was given - which is why
    the caller needs a *stable* default password (see `seed_credentials.py`)
    for this to actually reuse anything across runs rather than just
    failing every persona past the first one. Each returned account carries
    `reused`, so a caller can report how much of the run was new.
    """
    accounts = []
    working_code = invite_code
    for index in range(count):
        username, display = seed_content.persona(index, tag=username_tag)
        api = e2e_api.Api(base_url)
        body = {"username": username, "display_name": display,
                 "password": password, "device_name": f"{device_prefix}-{index}"}
        if working_code:
            body["invite_code"] = working_code
        reused = False
        try:
            got = seed_backoff.call_with_backoff(
                lambda b=body: api.call("POST", "/auth/register", b))
        except urllib.error.HTTPError as exc:
            got, reused = _reuse_or_raise(
                api, exc, (username, password, device_prefix, index),
                working_code)
        api.token = got["access_token"]
        api.keep_signed_in(username, password, f"{device_prefix}-{index}")
        accounts.append({"username": username, "display_name": display,
                          "api": api, "reused": reused})
        if index == 0 and working_code is None and count > 1:
            working_code = _mint_invite_if_possible(api, count - 1)
    return accounts


def _reuse_or_raise(api, exc, who, working_code):
    """Handles a failed registration: 409 means the name exists, and 400 may
    too, since a claimed invite-only deployment refuses a codeless register
    before it looks at the username. A 400 whose login also fails is the
    original refusal, so it reports the invite hint instead."""
    username, password, device_prefix, index = who
    if exc.code in (400, 409):
        try:
            return _login_existing(api, username, password, device_prefix, index)
        except AccountSetupError:
            if exc.code == 409:
                raise
    hint = ("" if working_code else
            "; pass --invite-code, or --admin-username and "
            "--admin-password so this can mint one")
    raise AccountSetupError(
        f"could not register seed account {username!r}: "
        f"{seed_backoff.describe_error(exc)}{hint}") from exc


def _login_existing(api, username, password, device_prefix, index):
    """The 409 branch of `register_accounts`: `username` already exists,
    so this logs into it instead - returning `(tokens, True)` - or raises a
    clear `AccountSetupError` naming the mismatch when even that fails,
    most likely because the account was registered under a different
    password than this run's."""
    try:
        got = seed_backoff.call_with_backoff(
            lambda: api.login(username, password, device=f"{device_prefix}-{index}"))
        return got, True
    except urllib.error.HTTPError as exc:
        raise AccountSetupError(
            f"{username!r} already exists but could not log in with this "
            f"run's password: {seed_backoff.describe_error(exc)}; pass "
            "--password to match whatever it was registered with, or "
            "--username-tag for a separate, fresh cohort instead") from exc


def create_seed_channel(accounts, admin_api, channel_name):
    """Creates the day's channel with whichever caller holds MANAGE_CHANNELS.

    Prefers an already-authenticated admin; otherwise falls back to the
    first seed account, which only holds that permission when it just
    claimed a fresh, previously unclaimed deployment.
    """
    creator = admin_api or (accounts[0]["api"] if accounts else None)
    if creator is None:
        raise AccountSetupError("no account available to create the channel")
    try:
        return seed_backoff.call_with_backoff(
            lambda: creator.call(
                "POST", "/channels", {"name": channel_name, "kind": "text"}))
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            raise AccountSetupError(
                "the channel could not be created (403): the seed account "
                "has no MANAGE_CHANNELS permission. Point this at a fresh, "
                "unclaimed deployment so the first account auto-claims it, "
                "or pass --admin-username and --admin-password for an "
                "already-claimed one") from exc
        raise AccountSetupError(
            f"could not create the channel: "
            f"{seed_backoff.describe_error(exc)}") from exc
