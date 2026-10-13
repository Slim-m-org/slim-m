# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The invite landing page, set by an admin and read by someone signed out.

The admin fills the description, banner and icon in Space settings > Invites.
A browser with its storage wiped then opens "I have an invite" with a fresh
code, and the card it shows must carry what the admin set. The server is asked
what it holds at both ends, so a card that renders from stale local state fails.
"""
import time

import e2e_labels as L
import e2e_session
from e2e_api import Api, wait_until


# Composed in the app from "Choose"/"Replace" and the row's name, so not in e2e_labels.
CHOOSE_BANNER = "Choose banner"
CHOOSE_ICON = "Choose icon"
REPLACE_BANNER = "Replace banner"
REPLACE_ICON = "Replace icon"


def _open_invites(client):
    client.click(L.SPACE_MENU, settle=2)
    client.click(L.SPACE_SETTINGS, settle=3)
    client.click(L.INVITES, settle=3)


def _set_pictures(client, picture):
    client.wait_for(CHOOSE_BANNER)
    client.attach_file(CHOOSE_BANNER, picture, settle=0.1)
    client.wait_for(REPLACE_BANNER)
    client.attach_file(CHOOSE_ICON, picture, settle=0.1)
    client.wait_for(L.CROP_TITLE)
    client.click(L.USE_PICTURE, settle=4)
    client.wait_for(REPLACE_ICON)


def admin_sets_the_landing_page(admin_client, admin_api, picture):
    """Returns the description saved, after the server confirms it and both pictures."""
    text = f"A small corner for e2e {int(time.time())}"
    _open_invites(admin_client)
    admin_client.type_into(L.DESCRIPTION_FIELD, text)
    admin_client.click(L.SAVE_DESCRIPTION, settle=3)
    wait_until(admin_api.space_settings,
               lambda s: s.get("description") == text,
               "the server did not store the description")
    _set_pictures(admin_client, picture)
    admin_client.shot("landing-page-set")

    settings = wait_until(
        admin_api.space_settings,
        lambda s: s.get("banner_updated_at") and s.get("icon_updated_at"),
        "the server did not store the banner and icon")
    print(f"  the server holds the description and both pictures: {text!r}")
    return text, settings


def signed_out_sees_the_card(client, sign_in, server, secret, admin_client,
                             admin_api, picture):
    text, _ = admin_sets_the_landing_page(admin_client, admin_api, picture)
    code = admin_api.call("POST", "/invites", {})["code"]
    members = len(admin_api.members())
    try:
        e2e_session.sign_out(client)
        client.click(L.I_HAVE_AN_INVITE, settle=2)
        client.type_into(L.INVITE_SERVER, server)
        client.type_into(L.INVITE_CODE, code)
        client.click(L.ACCEPT_TERMS, settle=1)
        client.click(L.INVITE_CONTINUE, settle=4)
        client.wait_for(text)
        client.wait_for(f"{members} members")
        client.shot("invite-landing-card")
        print(f"  a signed-out browser saw the description and "
              f"{members} members on the landing card")

        check = Api(server).call("GET", f"/invites/{code}/check")
        community = check["community"]
        assert community["description"] == text, community
        assert community["member_count"] == members, community
        assert community["banner_updated_at"], community
        assert community["icon_updated_at"], community
        print("  and /invites/{code}/check carries the same card")
    finally:
        e2e_session.sign_back_in_as_bob(client, sign_in, server, secret)
        _clear_landing_page(admin_api)


def _clear_landing_page(admin_api):
    """Leaves the Space as the rest of the run found it."""
    admin_api.call("PATCH", "/space/settings", {"description": ""})
    for part in ("banner", "icon"):
        admin_api.status("DELETE", f"/space/{part}")
