// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category's Private switch and "Who can see this" (decision 0124): the
/// switch writes or lifts only `@everyone`'s View deny, the summary lists who
/// an Allow View row lets in, the unsynced warning names what a save here
/// does not reach, and the grid's `@everyone` column has no remove.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/view_access.dart';
import 'package:slimm_app/src/features/channels/widgets/category_private_section.dart';
import 'package:slimm_app/src/features/channels/widgets/category_unsynced_notice.dart';
import 'package:slimm_app/src/features/channels/widgets/who_can_see.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/role_ladder.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _roles = [
  api.Role(
    id: 'everyone',
    name: 'everyone',
    permissions: Perm.viewChannel,
    isEveryone: true,
    createdAt: 0,
  ),
  api.Role(
    id: 'mods',
    name: 'Mods',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
  ),
];

const _members = [
  api.UserProfile(id: 'ann', username: 'ann', displayName: 'Ann', createdAt: 0),
];

Channel _channel(String id, String categoryId) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: categoryId,
);

/// Overwrites per `/categories/<id>` or `/channels/<id>` path, applied the
/// way the server applies a batch: per entry, an all-zero pair removes it.
class _Server {
  _Server(this.rows, {Map<String, bool> synced = const {}})
    : synced = {...synced};

  final Map<String, List<Map<String, Object>>> rows;
  final Map<String, bool> synced;
  final writes = <String, List<Map<String, dynamic>>>{};
  final requests = <String>[];

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    final base = path.replaceAll(RegExp(r'/overwrites.*$'), '');
    if (request.method == 'POST' && path.endsWith('/sync')) synced[base] = true;
    if (request.method == 'DELETE') {
      final parts = path.split('/');
      rows[base]?.removeWhere(
        (o) => o['kind'] == parts[parts.length - 2] && o['id'] == parts.last,
      );
      return http.Response('', 204);
    }
    if (request.method == 'PUT') {
      final edits = ((jsonDecode(request.body) as Map)['overwrites'] as List)
          .cast<Map<String, dynamic>>();
      writes[base] = edits;
      final list = rows.putIfAbsent(base, () => []);
      for (final e in edits) {
        list.removeWhere((o) => o['kind'] == e['kind'] && o['id'] == e['id']);
        if (e['allow'] != 0 || e['deny'] != 0) {
          list.add(e.cast<String, Object>());
        }
      }
    }
    return http.Response(
      jsonEncode({
        'overwrites': rows[base] ?? const <Object>[],
        if (synced.containsKey(base)) 'synced': synced[base],
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Server server,
  Widget child, {
  int permissions = Perm.administrator | Perm.manageRoles,
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      rolesProvider.overrideWith((ref) async => _roles),
      membersProvider.overrideWith((ref) async => _members),
      myPermissionsProvider.overrideWith((ref) => permissions),
      roleLadderProvider.overrideWith(
        (ref) => RoleLadder(permissions: permissions, ranked: false),
      ),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await waitUntil(tester, () => server.requests.isNotEmpty);
}

Future<void> _tap(WidgetTester tester, Finder finder, _Server server) async {
  final before = server.requests.length;
  await tester.tap(finder);
  await waitUntil(tester, () => server.requests.length > before);
}

final _switch = find.byWidgetPredicate((w) => w is AppToggle);

Future<void> _turnOn(WidgetTester tester, _Server server) async {
  await tester.tap(_switch);
  await pumpFrames(tester);
  await _tap(tester, find.text('Make private'), server);
}

const _section = CategoryPrivateSection(categoryId: 'cat', name: 'Admin');

void main() {
  testWidgets('turning it on denies everyone View and keeps its other bits', (
    tester,
  ) async {
    final server = _Server({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': Perm.viewChannel,
          'deny': Perm.sendMessages,
        },
      ],
    });
    await _pump(tester, server, _section);
    expect(find.text('Everyone'), findsOneWidget);

    await _turnOn(tester, server);

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
    final server = _Server({});
    await _pump(tester, server, _section, permissions: Perm.manageRoles);

    await _turnOn(tester, server);

    final written = {
      for (final e in server.writes['/categories/cat']!) '${e['id']}': e,
    };
    expect(written['self']?['allow'], Perm.viewChannel);
    expect(written['everyone']?['deny'], Perm.viewChannel);
  });

  testWidgets('turning it off lifts only the View deny', (tester) async {
    final server = _Server({
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
    await _pump(tester, server, _section);

    await _tap(tester, _switch, server);

    expect(server.writes['/categories/cat'], [
      {'kind': 'role', 'id': 'everyone', 'allow': 0, 'deny': Perm.sendMessages},
    ]);
    expect(find.text('Everyone'), findsOneWidget);
  });

  testWidgets('a mixed state reads as private and lists who is let in', (
    tester,
  ) async {
    final server = _Server({
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
    await _pump(tester, server, _section);

    final toggle = tester.widget<AppToggle>(_switch);
    expect(toggle.value, isTrue);
    expect(find.text('Administrators'), findsOneWidget);
    expect(find.text('Always'), findsOneWidget);
    expect(find.text('Mods'), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget);
  });

  testWidgets('removing a viewer clears only their View allow', (tester) async {
    final server = _Server({
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
    await _pump(tester, server, _section);

    await _tap(tester, find.bySemanticsLabel('Remove Mods'), server);
    expect(server.writes['/categories/cat'], [
      {'kind': 'role', 'id': 'mods', 'allow': Perm.sendMessages, 'deny': 0},
    ]);

    await _tap(tester, find.bySemanticsLabel('Remove Ann'), server);
    expect(server.writes['/categories/cat'], [
      {'kind': 'member', 'id': 'ann', 'allow': 0, 'deny': 0},
    ], reason: 'an all-zero pair removes the row');
    expect(find.text('Ann'), findsNothing);
  });

  testWidgets('adding a role writes an Allow View row', (tester) async {
    final server = _Server({
      '/categories/cat': [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': 0,
          'deny': Perm.viewChannel,
        },
      ],
    });
    await _pump(tester, server, _section);

    await tester.tap(find.text('Add role or member'));
    await pumpFrames(tester);
    await _tap(tester, find.text('Mods').last, server);

    expect(server.writes['/categories/cat'], [
      {'kind': 'role', 'id': 'mods', 'allow': Perm.viewChannel, 'deny': 0},
    ]);
    expect(find.text('Mods'), findsOneWidget);
  });

  testWidgets('a channel row removed to nothing is deleted, not zeroed', (
    tester,
  ) async {
    final server = _Server({
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
    await _pump(
      tester,
      server,
      const WhoCanSee(target: ChannelViewTarget('c1')),
    );

    await _tap(tester, find.bySemanticsLabel('Remove Ann'), server);

    expect(
      server.requests,
      contains('DELETE /channels/c1/overwrites/member/ann'),
    );
    expect(server.requests.where((r) => r.startsWith('PUT')), isEmpty);
  });

  testWidgets(
    'the warning counts what keeps its own permissions and syncs it',
    (tester) async {
      final server = _Server(
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
      await _pump(
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
            _channel('c-own', 'cat'),
            _channel('c-follows', 'cat'),
            _channel('c-in-follower', 'sub-follows'),
            _channel('c-in-own-sub', 'sub-own'),
          ],
        ),
      );
      await waitUntil(tester, () => server.requests.length >= 5);

      expect(
        find.text(
          '1 sub-category and 2 channels have their own permissions and are '
          'not changed.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Show them'));
      await pumpFrames(tester);
      expect(find.text('dev'), findsOneWidget);
      expect(find.text('#c-own'), findsOneWidget);
      expect(find.text('#c-in-follower'), findsOneWidget);
      expect(find.text('#c-in-own-sub'), findsNothing);

      await tester.tap(find.text('Sync all'));
      await pumpFrames(tester);
      await _tap(tester, find.text('Sync'), server);
      await waitUntil(
        tester,
        () => server.requests.contains(
          'POST /channels/c-in-follower/overwrites/sync',
        ),
      );
      expect(
        server.requests.where((r) => r.endsWith('/overwrites/sync')).toList(),
        [
          'POST /categories/sub-own/overwrites/sync',
          'POST /channels/c-own/overwrites/sync',
          'POST /channels/c-in-follower/overwrites/sync',
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
    final server = _Server({
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
    await _pump(
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
