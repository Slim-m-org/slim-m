// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel permissions grid: the legend, the always-present `@everyone`
/// column, a cell's tri-state cycle, and a cell the caller cannot grant.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid_rows.dart';
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
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
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

Widget _wrap({
  List<api.ChannelOverwrite> overwrites = const [],
  int myPermissions = 0,
  MockClient? client,
  List<api.UserProfile> members = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith((ref) async => members),
      channelOverwritesProvider(
        _channel.id,
      ).overrideWith((ref) async => overwrites),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => myPermissions),
      if (client != null)
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: const Scaffold(body: ChannelPermissionsGrid(channel: _channel)),
    ),
  );
}

final _everyoneSend = find.byKey(
  ValueKey('cell:role:${_everyone.id}:${Perm.sendMessages}'),
);

void main() {
  testWidgets('the legend and the everyone column always show', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Inherit from role'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.byTooltip('everyone'), findsOneWidget);
  });

  testWidgets(
    'a bot column with no picture shows initials, not a blank square',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          overwrites: [
            const api.ChannelOverwrite(
              kind: api.OverwriteTarget.member,
              id: 'bot-1',
              allow: 0,
              deny: 0,
            ),
          ],
          members: [
            const api.UserProfile(
              id: 'bot-1',
              username: 'sample_bot',
              displayName: 'sample_bot',
              createdAt: 0,
              isBot: true,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // initialsFor strips symbols and uppercases the first two characters.
      expect(find.text('SA'), findsOneWidget);
    },
  );

  testWidgets('a grantable cell cycles inherit -> allow -> deny -> inherit', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(myPermissions: Perm.sendMessages));
    await tester.pumpAndSettle();

    final cell = _everyoneSend;
    expect(tester.widget<Cell>(cell).state, CellState.inherit);

    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(tester.widget<Cell>(cell).state, CellState.allow);

    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(tester.widget<Cell>(cell).state, CellState.deny);

    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(tester.widget<Cell>(cell).state, CellState.inherit);
  });

  testWidgets(
    'a cell the caller cannot grant only cycles between inherit and deny',
    (tester) async {
      await tester.pumpWidget(_wrap(myPermissions: 0));
      await tester.pumpAndSettle();

      final cell = _everyoneSend;
      expect(tester.widget<Cell>(cell).disabled, isTrue);

      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(tester.widget<Cell>(cell).state, CellState.deny);

      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(tester.widget<Cell>(cell).state, CellState.inherit);
    },
  );

  testWidgets('saving sends a batch with only the changed target', (
    tester,
  ) async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({'overwrites': <dynamic>[]}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(
      _wrap(myPermissions: Perm.sendMessages, client: client),
    );
    await tester.pumpAndSettle();

    await tester.tap(_everyoneSend);
    await tester.pumpAndSettle();

    expect(find.textContaining('unsaved change'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.method, 'PUT');
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    final overwrites = body['overwrites'] as List<dynamic>;
    expect(overwrites, hasLength(1));
    expect(overwrites.single['id'], _everyone.id);
    expect(overwrites.single['allow'], Perm.sendMessages);
  });
}
