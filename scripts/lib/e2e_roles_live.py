# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A role granted or taken away changes what bob's open screen offers, live.

Bob sits in the channel with a message of alice's under the pointer. Without
Manage Messages his menu has neither Pin nor Delete, and the server refuses
the same pin. Alice then grants him a role carrying that permission, and his
menu must grow both rows without a reload, the server must accept the pin,
and taking the role back must remove them again. A stale menu would offer an
action the server then refuses, or hide one he is entitled to.
"""
import time

import e2e_input as I
import e2e_labels as L

TIMEOUT = 20
MANAGE_MESSAGES = 1 << 3


def _labels_in_menu(client, text):
    row = client.wait_for(text)
    I.right_click(client, row["x"], row["y"])
    client.wait_for(L.MENU_COPY_TEXT)
    labels = {n["t"] for n in client.nodes()}
    client.dismiss_overlay()
    return labels


def _wait_menu(client, text, pin, delete):
    deadline = time.time() + TIMEOUT
    while True:
        labels = _labels_in_menu(client, text)
        if (L.MENU_PIN in labels) == pin and (L.MENU_DELETE in labels) == delete:
            return
        if time.time() >= deadline:
            client.shot("roles-menu")
            raise AssertionError(
                f"{client.name}: menu has Pin={L.MENU_PIN in labels} Delete={L.MENU_DELETE in labels}, "
                f"wanted Pin={pin} Delete={delete}")
        time.sleep(0.5)


def role_change_reaches_an_open_screen(b, admin, member):
    stamp = int(time.time())
    text = f"alice's line for the role check {stamp}"
    channel_id = admin.channel_named(L.TEXT_CHANNEL)["id"]
    b.click(L.TEXT_CHANNEL)
    b.wait_for(L.COMPOSER)
    message = admin.send_message(channel_id, text)
    pin_path = f"/channels/{channel_id}/messages/{message['id']}/pin"
    role_id = None
    try:
        _wait_menu(b, text, pin=False, delete=False)
        assert member.status("PUT", pin_path) == 403
        print("  without Manage Messages bob's menu has neither Pin nor Delete, and the server refuses the pin")

        role = admin.call("POST", "/roles", {"name": f"e2e-pinner-{stamp}",
                                             "permissions": MANAGE_MESSAGES})
        role_id = role["id"]
        member_id = member.me()["id"]
        admin.call("PUT", f"/members/{member_id}/roles/{role_id}")
        _wait_menu(b, text, pin=True, delete=True)
        b.shot("roles-granted")
        assert member.status("PUT", pin_path) in (200, 204)
        member.call("DELETE", pin_path)
        print("  granting the role gives his open menu both rows and the server takes the pin")

        admin.call("DELETE", f"/members/{member_id}/roles/{role_id}")
        _wait_menu(b, text, pin=False, delete=False)
        assert member.status("PUT", pin_path) == 403
        print("  taking it back removes them again, and the server refuses once more")
    finally:
        b.dismiss_overlay()
        if role_id:
            admin.status("DELETE", f"/roles/{role_id}")
        admin.status("DELETE", pin_path)
        admin.delete_message(channel_id, message["id"])
