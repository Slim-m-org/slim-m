# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Changing your own password, and an admin issuing a reset code.

Both ask for a password before they act, and both are driven through the
sheet a person sees: a wrong password stays on it with a sentence, the right
one goes through. What happened is then read from the server, not the screen.
"""
import time
import urllib.error

import e2e_labels as L
import e2e_session
from e2e_api import Api
from e2e_members import _wait_for_member_row

OLD = "old-pass-for-e2e-1"
NEW = "new-pass-for-e2e-2"


def _refused(api_call):
    try:
        api_call()
    except urllib.error.HTTPError as err:
        return err.code
    return 200


def _wait_until_gone(client, label, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if client.find(label) is None:
            return
        time.sleep(0.5)
    raise AssertionError(f"{client.name}: {label!r} never went away")


def change_own_password(client, sign_in, server, secret, admin):
    """The old password stops working, the new one works, other devices go."""
    username, _ = e2e_session.register_member(server, admin, OLD)
    other_device = Api(server)
    other_device.login(username, OLD, device="e2e-other-device")
    assert other_device.status("GET", "/me") == 200
    try:
        e2e_session.sign_out(client)
        sign_in(client, server, username, OLD)
        client.click(L.PERSONAL_SETTINGS, settle=3)
        client.click(L.ACCOUNT_PANE, settle=2)
        client.click(L.CHANGE_PASSWORD, settle=2)

        _fill_sheet(client, "not-the-password-1", NEW)
        client.wait_for(L.WRONG_PASSWORD)
        client.shot("password-wrong-current")
        assert client.find(L.NEW_PASSWORD, field=True), \
            "a refused password closed the sheet"
        print("  a wrong current password stayed on the sheet with a sentence")

        client.type_into(L.CURRENT_PASSWORD, OLD)
        client.click(L.CHANGE_PASSWORD, settle=3)
        client.wait_for(L.PASSWORD_CHANGED)
        client.shot("password-changed")
        print("  the right current password changed it, and the page says so")

        _assert_on_server(server, username, other_device)
    finally:
        e2e_session.sign_back_in_as_bob(client, sign_in, server, secret)


def _fill_sheet(client, current, new):
    client.type_into(L.CURRENT_PASSWORD, current)
    client.type_into(L.NEW_PASSWORD, new)
    client.type_into(L.REPEAT_PASSWORD, new)
    client.click(L.CHANGE_PASSWORD, settle=3)


def _assert_on_server(server, username, other_device):
    old = Api(server)
    assert _refused(lambda: old.login(username, OLD)) in (400, 401, 403), \
        "the old password still signs in"
    fresh = Api(server)
    fresh.login(username, NEW, device="e2e-after-change")
    assert fresh.status("GET", "/me") == 200
    assert other_device.status("GET", "/me") == 401, \
        "the member's other device is still signed in"
    print("  the server refuses the old password, accepts the new one, and "
          "signed the other device out")


def _issue_via_menu(client, display, password):
    """Member card, Moderate, then the reset-code sheet, up to Generate code."""
    client.click(L.TEXT_CHANNEL)
    if not client.find("Online"):
        client.click(L.MEMBER_LIST, settle=1.5)
    row = _wait_for_member_row(client, display)
    client.click(row["t"], settle=2)
    client.click(L.MODERATE, settle=2)
    client.click(L.RESET_CODE_ROW, settle=2)
    client.wait_for(L.YOUR_PASSWORD, field=True)
    client.type_into(L.YOUR_PASSWORD, password)
    client.click(L.GENERATE_CODE, settle=3)


def reset_code_asks_for_the_admins_password(client, server, secret, admin):
    """A wrong password issues nothing; the right one shows a spendable code."""
    username, display = e2e_session.register_member(server, admin, OLD)
    target = Api(server)
    target.login(username, OLD, device="e2e-locked-out")
    user_id = target.me()["id"]
    path = f"/admin/users/{user_id}/reset-code"
    assert admin.status("POST", path, {"password": "not-the-admin-pass"}) \
        == 403, "the API issued a code for a wrong password"

    _issue_via_menu(client, display, "not-the-admin-pass")
    client.wait_for(L.WRONG_PASSWORD)
    assert client.find(L.RESET_CODE_SHOWN) is None, \
        "a code was shown for a wrong password"
    client.shot("reset-code-wrong-password")
    print("  a wrong admin password stayed on the sheet and showed no code")

    client.type_into(L.YOUR_PASSWORD, secret)
    client.click(L.GENERATE_CODE, settle=3)
    client.wait_for(L.RESET_CODE_SHOWN)
    client.shot("reset-code-shown")
    code = _code_on_screen(client)
    print("  the right admin password showed a code")

    Api(server).call("POST", "/auth/reset", {"code": code,
                                             "new_password": NEW})
    assert target.status("GET", "/me") == 401, \
        "spending the code left the member's session alive"
    Api(server).login(username, NEW, device="e2e-recovered")
    print("  the code on the sheet is real: spending it set a new password")


def _code_on_screen(client):
    """The code is selectable text with no accessible node, so Copy code is
    pressed and the clipboard read: the only way a person gets it out too."""
    client.send("Browser.grantPermissions",
                {"permissions": ["clipboardReadWrite",
                                 "clipboardSanitizedWrite"]})
    client.click(L.COPY_CODE, settle=1.5)
    got = client.send("Runtime.evaluate", {
        "expression": "navigator.clipboard.readText()",
        "awaitPromise": True, "returnByValue": True})
    code = (got.get("result", {}).get("result", {}).get("value") or "").strip()
    assert len(code) >= 16, f"{client.name}: Copy code left {code!r}"
    return code
