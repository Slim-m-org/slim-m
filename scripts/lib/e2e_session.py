# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Throwaway accounts, and a browser that can be signed out and back in.

Scenarios that change a password, or need a signed-out browser, must not touch
alice or bob: the rest of the run holds their API sessions and browsers. Each
registers an account of its own, and a browser it signs out is signed back in as
bob before it returns, so the next scenario finds the state it expects.
"""
import secrets
import time

from e2e_api import Api


def register_member(server, admin, password):
    """A fresh member through the join gate, as (username, display name)."""
    suffix = secrets.token_hex(3)
    username = f"e2e{suffix}"
    display = f"Pat{suffix}"
    invite = admin.call("POST", "/invites", {})["code"]
    Api(server).call("POST", "/auth/register", {
        "username": username, "display_name": display, "password": password,
        "device_name": "e2e-fresh", "invite_code": invite})
    return username, display


def sign_out(client):
    """Wipes the browser's storage and lands on the signed-out flow."""
    origin = client.ev("location.origin")
    client.send("Storage.clearDataForOrigin",
                {"origin": origin, "storageTypes": "all"})
    client.send("Page.navigate", {"url": f"{origin}/"})
    time.sleep(4)
    client.enable_semantics()


def sign_back_in_as_bob(client, sign_in, server, secret):
    sign_out(client)
    sign_in(client, server, "bob", secret)
    client.wait_for("general")
