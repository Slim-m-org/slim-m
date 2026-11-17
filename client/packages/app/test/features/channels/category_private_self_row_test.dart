// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Private switch's own row for a caller without Administrator: written
/// only when no role of theirs keeps them in, and lifted again by Off.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/category_private_section.dart';
import 'package:slimm_app/src/permissions.dart';

import 'category_private_fixture.dart';

const _section = CategoryPrivateSection(categoryId: 'cat', name: 'Admin');

api.UserProfile _self({List<String> roles = const []}) => api.UserProfile(
  id: 'self',
  username: 'self',
  displayName: 'Self',
  createdAt: 0,
  roleIds: roles,
);

void main() {
  testWidgets('on then off leaves the category exactly as it was', (
    tester,
  ) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.sendMessages,
        },
      ],
    });
    await pumpPrivate(
      tester,
      server,
      _section,
      permissions: Perm.manageRoles,
      members: [_self(), ...privateMembers],
    );

    await turnPrivateOn(tester, server);
    expect(
      server.rows['/categories/cat']!.map((o) => o['id']),
      containsAll(['self', 'everyone']),
      reason: 'a caller no role keeps in gets their own row',
    );

    await tapAndWait(tester, privateSwitch, server);
    expect(server.rows['/categories/cat'], [
      {'kind': 'role', 'id': 'everyone', 'allow': 0, 'deny': Perm.sendMessages},
    ], reason: 'Off lifts the row On added, so synced children lose it too');
  });

  testWidgets('a caller a role of theirs keeps in gets no row of their own', (
    tester,
  ) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {'kind': 'role', 'id': 'mods', 'allow': Perm.viewChannel, 'deny': 0},
      ],
    });
    await pumpPrivate(
      tester,
      server,
      _section,
      permissions: Perm.manageRoles,
      members: [
        _self(roles: ['everyone', 'mods']),
      ],
    );

    await turnPrivateOn(tester, server);

    expect(server.writes['/categories/cat'], [
      {'kind': 'role', 'id': 'everyone', 'allow': 0, 'deny': Perm.viewChannel},
    ]);
  });

  testWidgets('off keeps a self row that carries other bits', (tester) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel,
        },
        {
          'kind': 'member',
          'id': 'self',
          'allow': Perm.viewChannel | Perm.sendMessages,
          'deny': 0,
        },
      ],
    });
    await pumpPrivate(
      tester,
      server,
      _section,
      permissions: Perm.manageRoles,
      members: [_self()],
    );

    await tapAndWait(tester, privateSwitch, server);

    expect(server.rows['/categories/cat'], [
      {'kind': 'member', 'id': 'self', 'allow': Perm.sendMessages, 'deny': 0},
    ]);
  });
}
