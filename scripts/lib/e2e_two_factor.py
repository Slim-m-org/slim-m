# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Two-factor sign-in, turned on and used from the settings screen like a person would.

A fresh member scans nothing: the setup key comes off the screen through its
Copy button and the codes are computed here exactly as an authenticator app
computes them (RFC 6238, SHA-1, 30 s, 6 digits). The server keeps the highest
step it has accepted, so every use waits for a step of its own. Signing out
goes through the Sign out button, so the token is revoked on the server rather
than only forgotten by the browser.
"""
import base64
import hashlib
import hmac
import re
import struct
import time

import e2e_labels as L
import e2e_session
from e2e_api import Api

PASSWORD = "two-factor-pass-1"
STEP = 30
RECOVERY = re.compile(r"[A-Z2-7]{5}(?:-[A-Z2-7]{5}){3}")


def totp(secret, at=None):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    mac = hmac.new(key, struct.pack(">Q", int((at or time.time()) // STEP)), hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    return f"{(struct.unpack('>I', mac[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000:06d}"


def _fresh_code(secret, after):
    """A code from a step later than [after], the last step the server accepted."""
    while int(time.time() // STEP) <= after:
        time.sleep(0.5)
    return int(time.time() // STEP), totp(secret)


def _clipboard_after(client, label):
    client.send("Browser.grantPermissions",
                {"permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
    client.click(label, settle=1)
    got = client.send("Runtime.evaluate", {
        "expression": "navigator.clipboard.readText()",
        "awaitPromise": True, "returnByValue": True})
    return (got.get("result", {}).get("result", {}).get("value") or "").strip()


def _open_account(client):
    client.dismiss_overlay()
    client.ev("location.hash = '#/channels'")
    client.click(L.PERSONAL_SETTINGS, settle=3)
    client.click(L.ACCOUNT_PANE, settle=2)


def _sign_out_with_the_button(client):
    _open_account(client)
    client.click(L.SIGN_OUT, settle=3)
    deadline = time.time() + 20
    while not (client.find(L.CONNECT_TO_SPACE) or client.find(L.USERNAME, field=True)):
        assert time.time() < deadline, f"{client.name}: Sign out never reached a signed-out screen"
        time.sleep(0.25)


def _sign_in_with_code(client, server, username, code):
    client.enable_semantics()
    if client.find(L.CONNECT_TO_SPACE):
        client.click(L.CONNECT_TO_SPACE)
        client.type_into(L.SERVER_ADDRESS, server)
        client.click(L.CONTINUE)
    client.type_into(L.USERNAME, username)
    client.type_into(L.PASSWORD, PASSWORD)
    client.click(L.SIGN_IN, settle=2)
    client.wait_for(L.TOTP_CODE_FIELD, field=True)
    client.type_into(L.TOTP_CODE_FIELD, code)
    client.click(L.SIGN_IN, settle=3)
    client.wait_url("#/channels")


def _password_alone_is_challenged(server, username):
    answer = Api(server).call("POST", "/auth/login", {
        "username": username, "password": PASSWORD, "device_name": "e2e-2fa-check"})
    return "totp_challenge" in answer and "access_token" not in answer


def sign_in_with_a_second_factor(b, sign_in, server, secret, admin):
    username, _ = e2e_session.register_member(server, admin, PASSWORD)
    try:
        e2e_session.sign_out(b)
        sign_in(b, server, username, PASSWORD)
        _open_account(b)
        b.click(L.TOTP_TURN_ON, settle=2)
        b.type_into(L.YOUR_PASSWORD, PASSWORD)
        b.click(L.CONTINUE, settle=2)
        key = _clipboard_after(b, L.TOTP_COPY_KEY).replace(" ", "").upper()
        assert re.fullmatch(r"[A-Z2-7]{16,}", key), f"the setup key reads {key!r}"

        b.type_into(L.TOTP_SETUP_FIELD, "000000" if totp(key) != "000000" else "111111")
        b.click(L.TOTP_CONFIRM, settle=2)
        assert b.find(L.TOTP_SETUP_FIELD, field=True), "a wrong code left the setup sheet"
        step, code = _fresh_code(key, -1)
        b.type_into(L.TOTP_SETUP_FIELD, code)
        b.click(L.TOTP_CONFIRM, settle=3)
        codes = RECOVERY.findall(_clipboard_after(b, L.TOTP_COPY_ALL))
        assert len(codes) == 10, f"expected ten recovery codes, got {codes}"
        b.click(L.DONE, settle=2)
        b.wait_for(f"{L.TOTP_RECOVERY_LEFT}10 left")
        b.shot("two-factor-on")
        assert _password_alone_is_challenged(server, username), "a password alone still signed in"
        print("  turned on from settings with a computed code; a password alone now gets a challenge")

        _sign_out_with_the_button(b)
        step, code = _fresh_code(key, step)
        _sign_in_with_code(b, server, username, code)
        print("  signed out with the button and back in with a fresh authenticator code")

        _sign_out_with_the_button(b)
        _sign_in_with_code(b, server, username, codes[0])
        _open_account(b)
        b.wait_for(f"{L.TOTP_RECOVERY_LEFT}9 left")
        b.shot("two-factor-recovery-used")
        print("  a recovery code signs in once and the screen counts nine left")

        b.click(L.TOTP_TURN_OFF, settle=2)
        step, code = _fresh_code(key, step)
        b.type_into(L.TOTP_CODE_FIELD, code)
        b.click(L.TOTP_TURN_OFF_SUBMIT, settle=3)
        b.wait_for(L.TOTP_TURN_ON)
        assert not _password_alone_is_challenged(server, username), "turning it off still asked for a code"
        print("  turning it off with a code lets the password alone sign in again")
    finally:
        e2e_session.sign_back_in_as_bob(b, sign_in, server, secret)
