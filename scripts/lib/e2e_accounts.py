# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Account-level behaviour: usernames ignoring case, and the push preview.

The preview scenario is API-only on purpose. The switch is reachable on iOS
alone (`notification_settings_rows.dart` hides it everywhere else), so a web
browser has no control to drive; what is worth checking is the part the move to
an account setting changed, that a second device inherits the choice.
"""
import time
import urllib.error

from e2e_api import Api

PUSH_PREVIEW = "/push/preview"


def _refused(api, path, body):
    try:
        api.call("POST", path, body)
    except urllib.error.HTTPError as err:
        return err.code
    return 200


def usernames_ignore_case(client, sign_in, server, secret, admin_api):
    """A name differing only by case is refused, and any case signs in.

    Registration is checked at the API with a real invite, so the refusal can
    only be about the name. The sign-in is through the screen: the browser's
    storage is wiped so it lands on the sign-in flow, then the account is
    entered with its name in capitals.
    """
    invite = admin_api.call("POST", "/invites", {})["code"]
    for name in ("ALICE", "Bob"):
        status = _refused(Api(server), "/auth/register", {
            "username": name, "display_name": f"{name} again",
            "password": secret, "device_name": "e2e-case",
            "invite_code": invite})
        assert status == 409, \
            f"registering {name!r} beside the existing account got {status}"
    print("  registering ALICE and Bob beside alice and bob was refused (409)")

    origin = client.ev("location.origin")
    client.send("Storage.clearDataForOrigin",
                {"origin": origin, "storageTypes": "all"})
    client.send("Page.navigate", {"url": f"{origin}/"})
    time.sleep(4)
    sign_in(client, server, "BOB", secret)
    client.wait_for("general")
    other = Api(server)
    other.login("BOB", secret, device="e2e-case")
    assert other.me()["username"] == "bob", other.me()
    print("  signing in through the screen as BOB reached the bob account")


def push_preview_is_account_wide(server, secret):
    """A second device sees the choice the first one made, and on by default."""
    first = Api(server)
    first.login("bob", secret, device="e2e-preview-1")
    assert first.call("GET", PUSH_PREVIEW) == {"include_content": True}, \
        "the preview is not on by default"
    try:
        saved = first.call("PUT", PUSH_PREVIEW, {"include_content": False})
        assert saved == {"include_content": False}, saved
        second = Api(server)
        second.login("bob", secret, device="e2e-preview-2")
        assert second.call("GET", PUSH_PREVIEW) == \
            {"include_content": False}, \
            "a second device did not inherit the choice"
        print("  turning the preview off on one device showed off on another")
    finally:
        first.call("PUT", PUSH_PREVIEW, {"include_content": True})
    assert Api(server, second.token).call("GET", PUSH_PREVIEW) == \
        {"include_content": True}, "the choice did not follow back on"
    print("  and turning it back on reached the other device too")
