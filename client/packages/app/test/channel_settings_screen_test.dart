// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which sections Channel settings shows depends on which of MANAGE_CHANNELS
/// and MANAGE_ROLES the caller holds - see `channel_settings_screen.dart`'s
/// own doc on why the two are gated separately rather than the whole screen
/// being all-or-nothing. Round trips through the API for the individual
/// sections are `channel_management_test.dart`'s own concern.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/screens/channel_settings_screen.dart';
import 'package:slimm_data/data.dart' show Channel, MessageStore, SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _channel = Channel(
  id: 'c1',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

/// A caller holding [permissions], looking at the Channel settings screen
/// for [_channel]. `/channels/c1/permissions` (the "Allow" gate's source in
/// the embedded permissions pane) answers with the same bitmask, so a caller
/// who can reach the pane at all also reads as able to allow every bit in it.
Widget _harness(int permissions) => UncontrolledProviderScope(
  container: ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      meProvider.overrideWith(
        (ref) async => api.Me(
          id: 'user-1',
          username: 'user-1',
          displayName: 'User',
          createdAt: 0,
          permissions: permissions,
        ),
      ),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/channels/c1/permissions') {
              return http.Response(
                jsonEncode({'permissions': permissions}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/channels/c1/overwrites') {
              return http.Response(
                jsonEncode({'overwrites': const <Object>[]}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/roles' ||
                request.url.path == '/members') {
              return http.Response(
                jsonEncode(const <Object>[]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('{}', 200);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
      storeProvider.overrideWith((ref) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return MessageStore(db);
      }),
    ],
  ),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: ChannelSettingsScreen(
      args: ChannelSettingsRouteArgs(channel: _channel, wasOpen: false),
    ),
  ),
);

void main() {
  testWidgets(
    'MANAGE_CHANNELS alone shows General and Danger zone, not permissions',
    (tester) async {
      await tester.pumpWidget(_harness(Perm.manageChannels));
      await tester.pumpAndSettle();

      expect(find.text('General'), findsOneWidget);
      expect(find.text('Danger zone'), findsOneWidget);
      expect(find.text('Delete channel...'), findsOneWidget);
      expect(find.byType(ChannelPermissionsGrid), findsNothing);
    },
  );

  testWidgets(
    'MANAGE_ROLES alone shows permissions, not General or Danger zone',
    (tester) async {
      await tester.pumpWidget(_harness(Perm.manageRoles));
      await tester.pumpAndSettle();

      expect(find.text('General'), findsNothing);
      expect(find.text('Danger zone'), findsNothing);
      expect(find.byType(ChannelPermissionsGrid), findsOneWidget);
    },
  );

  testWidgets('both bits show every section', (tester) async {
    await tester.pumpWidget(_harness(Perm.manageChannels | Perm.manageRoles));
    await tester.pumpAndSettle();

    expect(find.text('General'), findsOneWidget);
    expect(find.text('Danger zone'), findsOneWidget);
    expect(find.byType(ChannelPermissionsGrid), findsOneWidget);
  });

  testWidgets('neither bit shows a stated reason, not an empty screen', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    await tester.pumpAndSettle();

    expect(find.text('General'), findsNothing);
    expect(find.text('Danger zone'), findsNothing);
    expect(find.byType(ChannelPermissionsGrid), findsNothing);
    expect(find.textContaining("this channel's settings"), findsOneWidget);
  });

  testWidgets(
    'the channel is locked here: no picker to change it, unlike the Space '
    'settings entry point',
    (tester) async {
      await tester.pumpWidget(_harness(Perm.manageChannels | Perm.manageRoles));
      await tester.pumpAndSettle();

      expect(find.text('Choose a channel'), findsNothing);
    },
  );
}
