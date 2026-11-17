// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space owner holds every permission whatever their roles, the way the
/// server's evaluator rules it, so every gate read off the viewer's own bits
/// offers the owner everything.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';

api.Me _me({bool owner = false, int permissions = 0, int? timedOutUntil}) =>
    api.Me(
      id: 'user-self',
      username: 'self',
      displayName: 'self',
      createdAt: 0,
      permissions: permissions,
      timedOutUntil: timedOutUntil,
      isOwner: owner,
      reportsRoleLadder: true,
    );

const _elevated = api.Role(
  id: 'top',
  name: 'top',
  permissions: Perm.administrator | Perm.manageRoles,
  isEveryone: false,
  createdAt: 0,
  position: 99,
);

const _senior = api.UserProfile(
  id: 'maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  topRolePosition: 99,
);

Future<ProviderContainer> _signedInAs(api.Me me) async {
  final container = ProviderContainer(
    overrides: [meProvider.overrideWith((ref) async => me)],
  );
  addTearDown(container.dispose);
  container.listen(meProvider, (_, _) {});
  await container.read(meProvider.future);
  return container;
}

void main() {
  test('every named bit is one the server defines, and all of them', () {
    expect(Perm.all, (1 << 22) - 1);
    for (final (bit, _) in Perm.editable) {
      expect(Perm.all.hasPermission(bit), isTrue, reason: '$bit');
    }
  });

  test('the owner holds every bit whatever the server sent', () {
    expect(_me(owner: true).heldPermissions, Perm.all);
    expect(
      _me(permissions: Perm.viewChannel).heldPermissions,
      Perm.viewChannel,
    );
    final timedOut = _me(
      owner: true,
      permissions: Perm.viewChannel,
      timedOutUntil: 1,
    );
    expect(
      timedOut.heldPermissions,
      Perm.viewChannel,
      reason: 'the server subtracted it',
    );
  });

  test(
    'the owner with no roles passes every gate the viewer\'s bits feed',
    () async {
      final container = await _signedInAs(_me(owner: true));
      expect(container.read(myPermissionsProvider), Perm.all);
      final ladder = container.read(roleLadderProvider);
      expect(ladder.lockOf(_elevated, member: _senior, held: false), isNull);
      expect(ladder.outranks(_senior), isTrue);
    },
  );

  test('anyone else keeps only the bits the server sent', () async {
    final container = await _signedInAs(_me(permissions: Perm.manageRoles));
    expect(container.read(myPermissionsProvider), Perm.manageRoles);
    final ladder = container.read(roleLadderProvider);
    expect(ladder.lockOf(_elevated, member: _senior, held: false), isNotNull);
    expect(ladder.outranks(_senior), isFalse);
  });
}
