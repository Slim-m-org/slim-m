# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Personal settings and Space settings, which are two screens on purpose.

The split is recent: one screen used to carry both, so a member with no
permissions saw a Space section they could do nothing with. These check the
two are reachable independently, and that what they change actually changes.
"""
import time

import e2e_labels as L


def _open_personal(client):
    """Each scenario starts from the channel list, so each finds its own way."""
    if '#/settings' not in (client.ev('location.href') or '') or \
            client.find(L.ROLES):
        client.click(L.PERSONAL_SETTINGS, settle=3)


def _open_space(client):
    if '#/settings/space' not in (client.ev('location.href') or ''):
        client.click(L.SPACE_MENU, settle=2)
        client.click(L.SPACE_SETTINGS, settle=3)


def personal_settings_reachable(client):
    """The footer control opens personal settings, never Space settings."""
    client.click(L.PERSONAL_SETTINGS, settle=3)
    client.wait_url('#/settings')
    client.wait_for(L.CHANGE_AVATAR)
    assert not client.find(L.ROLES), \
        'personal settings is showing Space settings'
    client.shot('personal-settings')
    print('  personal settings opens on its own, with no Space section in it')


def change_theme(client):
    """A preference that persists is a preference that was actually stored.

    The control relabelling itself is a local Riverpod state change and would
    say the same thing whether or not `ThemeController.select` ever reached
    `SharedPreferences`; the storage key it writes is read back directly.
    """
    _open_personal(client)
    client.click(L.APPEARANCE_PANE, settle=2)
    client.wait_for(L.THEME_DARK)
    client.click(L.THEME_DARK, settle=2)

    # Theme is per Space: the key is flutter.slimm.space.<origin>.slimm.appearance.theme.
    stored = client.ev(
        "(function(){var k=Object.keys(localStorage).find(function(k){"
        "return k.indexOf('flutter.')===0&&k.endsWith('slimm.appearance.theme');});"
        "return k?JSON.parse(localStorage.getItem(k)):null;})()")
    assert stored == 'dark', f'nothing durable recorded the choice: {stored!r}'
    print('  theme changed to Dark, and it was actually written to storage')


def change_status(client, api):
    """Presence is a real server-side state, not a local badge.

    `status_for` answers Offline for anyone with no live socket regardless of
    their stored preference, so this also depends on the browser client's own
    WebSocket staying up; the poll below only absorbs a reconnect, not an
    account that dropped its last connection.

    Driven from the rail footer, which is where this choice is made. Personal
    settings carried a duplicate of it until 2026-09-10 and no longer does, so
    this leaves settings first - the scenario before it ends up inside them.
    """
    if not client.find(L.CHANGE_STATUS):
        client.click(L.BACK_TO_CHANNELS, settle=3)
    client.click(L.CHANGE_STATUS, settle=2)
    client.wait_for(L.DND)
    client.click(L.DND, settle=3)
    # The footer's own line: the presence word for the state just chosen.
    client.wait_for('do not disturb')

    me_id = api.me()['id']
    deadline = time.time() + 20
    status = None
    while time.time() < deadline:
        rows = api.call('GET', f'/presence?ids={me_id}')
        row = next((r for r in rows if r['user_id'] == me_id), None)
        status = row['status'] if row else None
        if status == 'dnd':
            break
        time.sleep(0.25)
    assert status == 'dnd', f'the server still reports status {status!r}'
    print('  status changed to do-not-disturb, and the server agrees')


def upload_avatar(client, api, path):
    """Upload a picture and check the server serves it back."""
    _open_personal(client)
    # The avatar opens a photo menu first; see avatar_settings_section.dart.
    client.click(L.CHANGE_AVATAR, settle=2)
    client.attach_file('Choose photo', path)
    # A picked picture is cropped before it is uploaded, so the sheet has to be
    # answered; nothing reaches the server until it is.
    client.wait_for(L.CROP_TITLE)
    client.click(L.USE_PICTURE, settle=4)
    deadline = time.time() + 40
    served = None
    while time.time() < deadline:
        me = api.me()
        if me.get('avatar_updated_at'):
            served = me
            break
        time.sleep(0.5)
    assert served, 'the server recorded no avatar'
    body = api.call('GET', f'/users/{served["id"]}/avatar')
    assert body and len(body) > 100, 'the avatar served back empty'
    client.shot('avatar-uploaded')
    print(f'  an avatar was stored and served back, {len(body)} bytes')


def space_settings_reachable(client):
    """The Space menu opens Space settings, which personal settings is not."""
    _open_space(client)
    client.wait_url('#/settings/space')
    # Who can join is a row inside Invites now, not a pane; see #1256.
    for label in ('Reports', L.INVITES, L.ROLES):
        client.wait_for(label)
    assert not client.find(L.CHANGE_AVATAR), \
        'Space settings is showing personal settings'
    client.shot('space-settings')
    print('  Space settings opens on its own, with its sections')


def change_join_policy(client, api):
    """Who can join is one row in the database and the whole security model."""
    _open_space(client)
    before = api.space_settings()['join_policy']
    # Through Invites since #1256; the row inside it opens the picker.
    client.click(L.INVITES, settle=2)
    client.wait_for(L.WHO_CAN_JOIN_ROW)
    client.click(L.WHO_CAN_JOIN_ROW, settle=2)
    client.wait_for(L.JOIN_OPEN)
    client.click(L.JOIN_OPEN, settle=3)

    deadline = time.time() + 30
    while time.time() < deadline:
        if api.space_settings()['join_policy'] == 'open':
            break
        time.sleep(0.5)
    after = api.space_settings()['join_policy']
    assert after == 'open', f'join policy is {after!r}, not open'
    assert after != before, 'the join policy did not change'
    # Unauthenticated callers are told, because the sign-up screen has to know
    # before an account exists.
    assert api.version()['invite_required'] is False, \
        '/version still says an invite is required'
    print(f'  join policy {before} -> {after}, and /version agrees')

    client.click(L.WHO_CAN_JOIN_ROW, settle=2)
    client.click(L.JOIN_INVITE, settle=3)
    deadline = time.time() + 30
    while time.time() < deadline:
        if api.space_settings()['join_policy'] == 'invite':
            break
        time.sleep(0.5)
    assert api.space_settings()['join_policy'] == 'invite', \
        'the Space was left open'
    print('  and back to invite-only, so the run leaves nothing open')
