// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid follows the server's role ladder: a column for a role
/// or member level with or above the viewer is read-only, and a save that
/// touches one is refused whole before anything is sent.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid_rows.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _everyone = api.Role(
  id: 'role-everyone',
  name: '@everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

const _helper = api.Role(
  id: 'role-helper',
  name: 'helper',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
  position: 2,
);

const _admin = api.Role(
  id: 'role-admin',
  name: 'admin',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
  position: 8,
);

const _senior = api.UserProfile(
  id: 'user-sam',
  username: 'sam',
  displayName: 'sam',
  createdAt: 0,
  topRolePosition: 8,
);

const _channel = Channel(
  id: 'c-general',
  name: 'general',
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
);

const _send = Perm.sendMessages;

api.Me _me(int top) => api.Me(
  id: 'self',
  username: 'self',
  displayName: 'self',
  createdAt: 0,
  permissions: Perm.manageRoles | _send,
  topRolePosition: top,
  reportsRoleLadder: true,
);

class _Rig {
  var top = 5;
  final writes = <String>[];

  late final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      meProvider.overrideWith((ref) async => _me(top)),
      rolesProvider.overrideWith((ref) async => [_everyone, _helper, _admin]),
      membersProvider.overrideWith((ref) async => [_senior]),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => Perm.manageRoles | _send),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(_answer),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );

  Future<http.Response> _answer(http.Request request) async {
    if (request.method != 'GET') {
      writes.add('${request.method} ${request.url.path}');
    }
    return http.Response(
      jsonEncode({
        'overwrites': [
          for (final (kind, id) in [
            ('role', _helper.id),
            ('role', _admin.id),
            ('member', _senior.id),
          ])
            {'kind': kind, 'id': id, 'allow': _send, 'deny': 0},
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: ChannelPermissionsGrid(channel: _channel)),
        ),
      ),
    );
    await _settle(tester);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _cell(String columnKey) =>
    find.byKey(ValueKey('cell:$columnKey:$_send'));

Cell _cellOf(WidgetTester tester, String columnKey) =>
    tester.widget<Cell>(_cell(columnKey));

void main() {
  testWidgets('a role or member at or above you is read-only, below is not', (
    tester,
  ) async {
    await _Rig().pump(tester);

    expect(_cellOf(tester, 'role:${_helper.id}').disabled, isFalse);
    expect(_cellOf(tester, 'role:${_everyone.id}').disabled, isFalse);
    expect(_cellOf(tester, 'role:${_admin.id}').disabled, isTrue);
    expect(_cellOf(tester, 'member:${_senior.id}').disabled, isTrue);
    final remove = tester.widget<AppIconButton>(
      find.widgetWithIcon(AppIconButton, AppIcons.dismiss).at(2),
    );
    expect(remove.semanticLabel, 'Remove admin from this grid');
    expect(remove.onPressed, isNull);
  });

  testWidgets('a save that touches a column now above you sends nothing', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);

    await tester.tap(find.bySemanticsLabel('Remove helper from this grid'));
    await tester.pump();
    await tester.tap(_cell('role:${_everyone.id}'));
    await tester.pump();
    rig
      ..top = 1
      ..container.invalidate(meProvider);
    await _settle(tester);
    await tester.tap(find.text('Save changes'));
    await _settle(tester);

    expect(rig.writes, isEmpty, reason: 'no removal goes out ahead of a 403');
    expect(
      find.text(
        'Could not save the permissions grid. helper ranks level with or '
        'above you, so leave it as it was.',
      ),
      findsOneWidget,
    );
  });
}
