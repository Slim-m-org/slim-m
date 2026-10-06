# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Roles, reporting, blocking: the parts that decide what people may do.

Two of these are driven at the API rather than through the screen. Reporting
and blocking live behind the message context menu. A click dispatched at a
semantics element does not open it, which is why they began as API calls; a
genuine right-click does (see e2e_input.py and e2e_message_menu.py), so they
could move to the UI. They stay at the API because what matters here is that
the server files the report and refuses the unauthorised caller.

Permissions are deliberately checked at the API too. Hiding a button is not
access control; refusing the request is, and that is the half worth testing.
"""
import time

import e2e_labels as L


def create_role(client, api):
    """A role is created through the UI and read back from the server."""
    client.click(L.SPACE_MENU, settle=2)
    client.click(L.SPACE_SETTINGS, settle=3)
    client.click(L.ROLES, settle=4)
    before = {r['name'] for r in api.roles()}

    client.click(L.NEW_ROLE, settle=2)
    client.type_into(L.ROLE_NAME, 'moderator')
    client.click(L.CREATE_ROLE, settle=4)

    deadline = time.time() + 30
    while time.time() < deadline:
        if 'moderator' in {r['name'] for r in api.roles()}:
            break
        time.sleep(2)
    after = {r['name'] for r in api.roles()}
    assert 'moderator' in after, f'the server has no moderator role: {after}'
    assert after != before, 'the role list did not change'
    client.shot('role-created')
    print(f'  a role was created through the UI; the server has {sorted(after)}')


def report_a_message(reporter_api, admin_api, channel_id, needle):
    """A report reaches a queue only the right permission can read."""
    target = reporter_api.message_with(channel_id, needle)
    reporter_api.call('POST', '/reports', {
        'subject_kind': 'message',
        'subject_id': target['id'],
        'reason': 'e2e: an automated check, safe to dismiss'})

    deadline = time.time() + 20
    while time.time() < deadline and not admin_api.reports():
        time.sleep(2)
    filed = admin_api.reports()
    assert filed, 'the server holds no report'
    assert any(r.get('subject_id') == target['id'] for r in filed), \
        'the queue holds reports, but not the one just filed'
    print(f'  a message was reported and reached the queue: {len(filed)} open')
    return filed


def block_and_unblock(api, other_id):
    """Blocking is account state the server keeps, not a local filter."""
    api.call('POST', f'/blocks/{other_id}')
    ids = api.blocks()
    assert other_id in ids, f'{other_id} is not in {ids}'
    print(f'  a block was stored: {ids}')

    api.call('DELETE', f'/blocks/{other_id}')
    ids = api.blocks()
    assert other_id not in ids, f'{other_id} survived the unblock: {ids}'
    print('  and unblocking removed it, so the run leaves nothing blocked')


def capabilities_are_honest(api):
    """The handshake must name the two routes this run has just used.

    A client warns someone off a server whose /version omits these, so an
    advertisement that drifted from the router would either scare people away
    from a healthy deployment or hide a broken one. This runs after reporting
    and blocking on purpose: both are known to work at this point, so a
    missing name here is the advertisement being wrong, not the feature.
    """
    advertised = api.version().get('capabilities')
    assert advertised is not None, \
        'the server advertises no capability list at all'
    for name in ('report', 'block'):
        assert name in advertised, \
            f'{name} is missing from {advertised}, and this run just used it'
    print(f'  the server advertises what it serves: {sorted(advertised)}')


def permissions_are_enforced(member_api, admin_api):
    """An ordinary member must not be able to do an administrator's work.

    Each body below is one the server would accept from an administrator, so
    the only reason left to refuse it is the caller. That matters: the first
    version of this sent `permissions` as a string, earned a 400 for a bad
    body, and would have passed just as happily against a server with no
    permission checks in it at all.
    """
    queue = '/reports'
    refusals = [
        ('POST', '/roles', {'name': 'should-not-exist', 'permissions': 0}),
        ('PATCH', '/space/settings', {'join_policy': 'open'}),
        ('GET', queue, None),
    ]
    for method, path, body in refusals:
        code = member_api.status(method, path, body)
        assert code in (401, 403), \
            f'{method} {path} answered {code} for an ordinary member'
        print(f'  {method} {path} refused an ordinary member with {code}')

    assert admin_api.status('GET', queue) == 200, \
        'the administrator cannot read the report queue'
    assert 'should-not-exist' not in {r['name'] for r in admin_api.roles()}, \
        'the refused role was created anyway'
    print('  and the administrator can still do all three')
