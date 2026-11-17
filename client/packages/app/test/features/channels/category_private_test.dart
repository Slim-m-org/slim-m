// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category's Private switch and "Who can see this" (decision 0125): the
/// switch writes or lifts only `@everyone`'s View deny, the summary lists who
/// an Allow View row lets in, the unsynced warning names what a save here
/// does not reach, and the grid's `@everyone` column has no remove.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/view_access.dart';
import 'package:slimm_app/src/features/channels/widgets/category_private_section.dart';
import 'package:slimm_app/src/features/channels/widgets/category_unsynced_notice.dart';
import 'package:slimm_app/src/features/channels/widgets/who_can_see.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'category_private_fixture.dart';

const _section = CategoryPrivateSection(categoryId: 'cat', name: 'Admin');

void main() {
  testWidgets('turning it on denies everyone View and keeps its other bits', (
    tester,
  ) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': Perm.viewChannel,
          'deny': Perm.sendMessages,
        },
      ],
    });
    await pumpPrivate(tester, server, _section);
    expect(find.text('Everyone'), findsOneWidget);

    await turnPrivateOn(tester, server);

    expect(server.writes['/categories/cat'], [
      {
        'kind': 'role',
        'id': 'everyone',
        'allow': 0,
        'deny': Perm.sendMessages | Perm.viewChannel,
      },
    ], reason: 'an administrator sees it anyway, so no row for them');
    expect(find.text('Administrators'), findsOneWidget);
    expect(find.text('Everyone'), findsNothing);
  });

  testWidgets('a caller who is not an administrator keeps their own view', (
    tester,
  ) async {
    final server = OverwriteServer({});
    await pumpPrivate(tester, server, _section, permissions: Perm.manageRoles);

    await turnPrivateOn(tester, server);

    final written = {
      for (final e in server.writes['/categories/cat']!) '${e['id']}': e,
    };
    expect(written['self']?['allow'], Perm.viewChannel);
    expect(written['everyone']?['deny'], Perm.viewChannel);
  });

  testWidgets('turning it off lifts only the View deny', (tester) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel | Perm.sendMessages,
        },
        {'kind': 'role', 'id': 'mods', 'allow': Perm.viewChannel, 'deny': 0},
      ],
    });
    await pumpPrivate(tester, server, _section);

    await tapAndWait(tester, privateSwitch, server);

    expect(server.writes['/categories/cat'], [
      {'kind': 'role', 'id': 'everyone', 'allow': 0, 'deny': Perm.sendMessages},
    ]);
    expect(find.text('Everyone'), findsOneWidget);
  });

  testWidgets('a mixed state reads as private and lists who is let in', (
    tester,
  ) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel,
        },
        {'kind': 'role', 'id': 'mods', 'allow': Perm.viewChannel, 'deny': 0},
        {'kind': 'member', 'id': 'ann', 'allow': Perm.viewChannel, 'deny': 0},
        {'kind': 'role', 'id': 'other', 'allow': 0, 'deny': Perm.viewChannel},
      ],
    });
    await pumpPrivate(tester, server, _section);

    final toggle = tester.widget<AppToggle>(privateSwitch);
    expect(toggle.value, isTrue);
    expect(find.text('Administrators'), findsOneWidget);
    expect(find.text('Always'), findsOneWidget);
    expect(find.text('Mods'), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget);
  });

  testWidgets('removing a viewer clears only their View allow', (tester) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel,
        },
        {
          'kind': 'role',
          'id': 'mods',
          'allow': Perm.viewChannel | Perm.sendMessages,
          'deny': 0,
        },
        {'kind': 'member', 'id': 'ann', 'allow': Perm.viewChannel, 'deny': 0},
      ],
    });
    await pumpPrivate(tester, server, _section);

    await tapAndWait(tester, find.bySemanticsLabel('Remove Mods'), server);
    expect(server.writes['/categories/cat'], [
      {'kind': 'role', 'id': 'mods', 'allow': Perm.sendMessages, 'deny': 0},
    ]);

    await tapAndWait(tester, find.bySemanticsLabel('Remove Ann'), server);
    expect(server.writes['/categories/cat'], [
      {'kind': 'member', 'id': 'ann', 'allow': 0, 'deny': 0},
    ], reason: 'an all-zero pair removes the row');
    expect(find.text('Ann'), findsNothing);
  });

  testWidgets('adding a role writes an Allow View row', (tester) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel,
        },
      ],
    });
    await pumpPrivate(tester, server, _section);

    await tester.tap(find.text('Add role or member'));
    await pumpFrames(tester);
    await tapAndWait(tester, find.text('Mods').last, server);

    expect(server.writes['/categories/cat'], [
      {'kind': 'role', 'id': 'mods', 'allow': Perm.viewChannel, 'deny': 0},
    ]);
    expect(find.text('Mods'), findsOneWidget);
  });

  testWidgets('a channel row removed to nothing is deleted, not zeroed', (
    tester,
  ) async {
    final server = OverwriteServer({
      '/channels/c1': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel,
        },
        {'kind': 'member', 'id': 'ann', 'allow': Perm.viewChannel, 'deny': 0},
      ],
    });
    await pumpPrivate(
      tester,
      server,
      const WhoCanSee(target: ChannelViewTarget('c1')),
    );

    await tapAndWait(tester, find.bySemanticsLabel('Remove Ann'), server);

    expect(
      server.requests,
      contains('DELETE /channels/c1/overwrites/member/ann'),
    );
    expect(server.requests.where((r) => r.startsWith('PUT')), isEmpty);
  });

  testWidgets(
    'the warning counts what keeps its own permissions and syncs it',
    (tester) async {
      final server = OverwriteServer(
        {},
        synced: {
          '/categories/sub-own': false,
          '/categories/sub-follows': true,
          '/channels/c-own': false,
          '/channels/c-follows': true,
          '/channels/c-in-follower': false,
          '/channels/c-in-own-sub': false,
        },
      );
      await pumpPrivate(
        tester,
        server,
        CategoryUnsyncedNotice(
          categoryId: 'cat',
          categoryName: 'Admin',
          subCategories: const [
            ChannelCategoryRow(id: 'sub-own', name: 'dev', position: 0),
            ChannelCategoryRow(id: 'sub-follows', name: 'bots', position: 1),
          ],
          channels: [
            privateChannel('c-own', 'cat'),
            privateChannel('c-follows', 'cat'),
            privateChannel('c-in-follower', 'sub-follows'),
            privateChannel('c-in-own-sub', 'sub-own'),
          ],
        ),
      );
      await waitUntil(tester, () => server.requests.length >= 5);

      expect(
        find.text(
          '1 sub-category and 3 channels have their own permissions and are '
          'not changed.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Show them'));
      await pumpFrames(tester);
      expect(find.text('dev'), findsOneWidget);
      expect(find.text('#c-own'), findsOneWidget);
      expect(find.text('#c-in-follower'), findsOneWidget);
      expect(find.text('#c-in-own-sub'), findsOneWidget);

      await tester.tap(find.text('Sync all'));
      await pumpFrames(tester);
      await tapAndWait(tester, find.text('Sync'), server);
      await waitUntil(
        tester,
        () => server.requests.contains(
          'POST /channels/c-in-own-sub/overwrites/sync',
        ),
      );
      expect(
        server.requests.where((r) => r.endsWith('/overwrites/sync')).toList(),
        [
          'POST /categories/sub-own/overwrites/sync',
          'POST /channels/c-own/overwrites/sync',
          'POST /channels/c-in-follower/overwrites/sync',
          'POST /channels/c-in-own-sub/overwrites/sync',
        ],
      );
    },
  );

  test('the warning reads in the singular for one thing', () {
    expect(
      unsyncedMessage(0, 1),
      '1 channel has its own permissions and is not changed.',
    );
    expect(
      unsyncedMessage(3, 0),
      '3 sub-categories have their own permissions and are not changed.',
    );
  });

  testWidgets('the everyone column has no remove; other columns do', (
    tester,
  ) async {
    final server = OverwriteServer({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel,
        },
        {'kind': 'role', 'id': 'mods', 'allow': Perm.viewChannel, 'deny': 0},
      ],
    });
    await pumpPrivate(
      tester,
      server,
      const ChannelPermissionsGrid.forCategory(categoryId: 'cat'),
    );

    expect(find.bySemanticsLabel('Remove Mods from this grid'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Remove everyone from this grid'),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel(
        RegExp('^Applies to everyone and cannot be removed'),
      ),
      findsOneWidget,
    );
  });
}
