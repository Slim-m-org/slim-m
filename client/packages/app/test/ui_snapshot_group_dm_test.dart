// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Group DMs (decision 0095): the rail row and header with stacked avatars,
/// the new-group sheet and the members sheet, at a phone and a desktop width
/// in dark and light. The overflow assertion runs everywhere; the PNGs are
/// written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/group_dm_members_sheet.dart';
import 'package:slimm_app/src/features/channels/widgets/new_group_dm_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/home_shell.dart';

import 'ui_snapshot_support.dart';

Map<String, Object?> _person(String id, String name) => {
  'id': id,
  'username': name.toLowerCase(),
  'display_name': name,
  'created_at': 0,
};

final _group = {
  'channel_id': 'c-group',
  'user': _person('p-kiki', 'Kiki'),
  'unread': 2,
  'created_at': DateTime(2026, 10, 20).millisecondsSinceEpoch,
  'group': {
    'name': null,
    'members': [
      _person('user-nick', 'Nick'),
      _person('p-kiki', 'Kiki'),
      _person('p-ada', 'Ada'),
      _person('p-bo', 'Bo'),
    ],
  },
};

final _pair = {
  'channel_id': 'c-pair',
  'user': _person('p-kiki', 'Kiki'),
  'unread': 0,
  'created_at': DateTime(2026, 10, 1).millisecondsSinceEpoch,
};

final _members = [
  _person('user-nick', 'Nick'),
  _person('p-kiki', 'Kiki'),
  _person('p-ada', 'Ada'),
  _person('p-bo', 'Bo'),
  _person('p-cy', 'Cy'),
  _person('p-di', 'Di'),
];

http.Client _client() => MockClient((request) async {
  if (request.method == 'GET') {
    switch (request.url.path) {
      case '/dms':
        return http.Response(
          jsonEncode([_group, _pair]),
          200,
          headers: {'content-type': 'application/json'},
        );
      case '/members':
        return http.Response(
          jsonEncode(_members),
          200,
          headers: {'content-type': 'application/json'},
        );
    }
  }
  return fixtureResponse(request);
});

List<Override> _overrides() => [
  apiProvider.overrideWith((ref) {
    final client = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: _client(),
    );
    ref.onDispose(client.close);
    return client;
  }),
];

Future<void> _seedGroup(WidgetTester tester) async {
  final shell = tester.element(find.byType(HomeShell));
  final container = ProviderScope.containerOf(shell);
  final store = await container.read(storeProvider.future);
  await store.upsertChannels(const [
    api.Channel(
      id: 'c-group',
      name: 'Kiki, Ada and Bo',
      kind: 'dm',
      createdAt: 0,
      dmMemberIds: ['user-nick', 'p-kiki', 'p-ada', 'p-bo'],
    ),
  ]);
  GoRouter.of(shell).go('/channels/c-group');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _openSheet(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  await _seedGroup(tester);
  unawaited(open(tester.element(find.byType(HomeShell))));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);
  for (final viewport in const ['phone-portrait', 'desktop']) {
    testWidgets('a group DM at $viewport fits its viewport', (tester) async {
      await renderSurface(
        tester,
        '/channels/c-group',
        viewport,
        darkAndLight,
        'group-dm-$viewport-$darkAndLight',
        overrides: _overrides(),
        afterSettle: _seedGroup,
      );
    });

    testWidgets('the new group sheet at $viewport fits its viewport', (
      tester,
    ) async {
      await renderSurface(
        tester,
        '/channels/c-group',
        viewport,
        darkAndLight,
        'group-dm-new-$viewport-$darkAndLight',
        overrides: _overrides(),
        afterSettle: (tester) => _openSheet(tester, showNewGroupDmSheet),
      );
    });

    testWidgets('the members sheet at $viewport fits its viewport', (
      tester,
    ) async {
      await renderSurface(
        tester,
        '/channels/c-group',
        viewport,
        darkAndLight,
        'group-dm-members-$viewport-$darkAndLight',
        overrides: _overrides(),
        afterSettle: (tester) => _openSheet(
          tester,
          (context) => showGroupDmMembersSheet(context, 'c-group'),
        ),
      );
    });
  }
}
