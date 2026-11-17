// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Private switch and an unsaved Advanced grid edit in one sheet: the
/// grid's save keeps the switch's write instead of undoing it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/category_private_section.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_rebase.dart';
import 'package:slimm_app/src/permissions.dart';

import '../../support/async_wait.dart';
import 'category_private_fixture.dart';

const _sheet = Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    CategoryPrivateSection(categoryId: 'cat', name: 'Admin'),
    ChannelPermissionsGrid.forCategory(categoryId: 'cat'),
  ],
);

void main() {
  testWidgets('a grid save after the switch keeps the category private', (
    tester,
  ) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {'kind': 'role', 'id': 'everyone', 'allow': 0, 'deny': 0},
      ],
    });
    await pumpPrivate(tester, server, _sheet);

    final send = find.byKey(
      const ValueKey('cell:role:everyone:${Perm.sendMessages}'),
    );
    await tester.ensureVisible(send);
    await tester.tap(send);
    await pumpFrames(tester);

    await tester.ensureVisible(privateSwitch);
    await turnPrivateOn(tester, server);
    await waitUntil(
      tester,
      () => server.requests.where((r) => r.startsWith('GET')).length >= 3,
    );

    final save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tapAndWait(tester, save, server);
    await waitUntil(
      tester,
      () => server.requests.where((r) => r.startsWith('PUT')).length >= 2,
    );

    expect(server.writes['/categories/cat'], [
      {
        'kind': 'role',
        'id': 'everyone',
        'allow': 0,
        'deny': Perm.sendMessages | Perm.viewChannel,
      },
    ], reason: 'the grid denied Send; the switch denied View');
  });

  test('a rebase keeps the bits edited here and takes the rest', () {
    const view = Perm.viewChannel;
    const send = Perm.sendMessages;
    expect(
      rebasePending(original: (0, 0), pending: (send, 0), fresh: (0, view)),
      (send, view),
    );
    expect(
      rebasePending(
        original: (0, send),
        pending: (0, 0),
        fresh: (0, send | view),
      ),
      (0, view),
      reason: 'a bit cleared here stays cleared',
    );
  });
}
