# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Seed a fresh deployment with the two accounts and voice channel the call needs.

Prints shell assignments for scripts/e2e.sh to eval. The first account
registered claims the deployment, so the second has to come in on an invite the
first one issues: that is the join gate working, not a quirk of the test.
"""
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

import e2e_api

CHANNEL = "lounge"
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]"}


def local_base(raw):
    """Refuse anywhere but this machine.

    The first account this creates claims the deployment and gets admin, so a
    mistyped address would hand that to somebody else's server.
    """
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme not in ("http", "https") or parsed.hostname not in LOCAL_HOSTS:
        sys.exit(f"refusing to seed a non-local address: {raw!r}")
    return raw.rstrip("/")


def call(base, path, body, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{base}{path}", data=json.dumps(body).encode(),
                                 headers=headers)
    try:
        return json.load(e2e_api.urlopen(req))
    except urllib.error.HTTPError as exc:
        sys.exit(f"{path} failed {exc.code}: {exc.read()[:300].decode()}")


def main():
    base = local_base(sys.argv[1])
    # Minted per run rather than written down, so nothing here is a credential
    # anyone could reuse against a deployment that outlives the test. Set
    # E2E_PASSWORD to pin it when debugging against a `--keep` stack, which is
    # the only way to sign in as these accounts by hand.
    secret = os.environ.get("E2E_PASSWORD") or secrets.token_urlsafe(16)

    alice = call(base, "/auth/register", {
        "username": "alice", "display_name": "Alice",
        "password": secret, "device_name": "e2e-a"})
    token = alice["access_token"]

    invite = call(base, "/invites", {}, token)["code"]
    call(base, "/auth/register", {
        "username": "bob", "display_name": "Bob", "password": secret,
        "device_name": "e2e-b", "invite_code": invite})

    channel = call(base, "/channels", {"name": CHANNEL, "kind": "voice"}, token)
    print(f'VOICE_ROOM="channel-{channel["id"]}"')
    print(f'VOICE_CHANNEL_NAME="{CHANNEL}"')
    print(f'VOICE_SECRET="{secret}"')


if __name__ == "__main__":
    main()
