// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The finding docs/decisions/0011-per-channel-permissions.md exists to fix:
/// a DM message-action menu offering Delete and Pin because the caller's
/// deployment-wide MANAGE_MESSAGES bit was consulted, when a DM's own
/// permissions (`DM_BASE`) can never grant either. Drives a real
/// `ChannelScreen` over a DM channel rather than `messageActionsFor` in
/// isolation, since the bug was in which provider that call site read, not
/// in the pure function itself.
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
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// The caller's own base bitmask grants MANAGE_MESSAGES deployment-wide -
/// the exact shape a moderator's account has in real use.
Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': Perm.manageMessages,
};

api.Message _fromAlice() => const api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: 1,
  content: 'hi',
  createdAt: 1000,
  editedAt: null,
);

http.Response _emptyJsonList() => http.Response(
  jsonEncode([]),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets(
    'a DM offers no Delete or Pin for the other participant\'s message, '
    'even though the caller\'s base permissions grant MANAGE_MESSAGES',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      await store.upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'Alice',
          kind: 'dm',
          createdAt: 0,
          dmParticipantId: 'alice',
        ),
      ]);
      await store.applyMessages([_fromAlice()]);

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          storeProvider.overrideWith((ref) async => store),
          syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
          // What the real per-channel route would answer for a DM: DM_BASE never carries MANAGE_MESSAGES.
          channelPermissionsProvider('c1').overrideWith((ref) async => 0),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (request.method == 'GET' && request.url.path == '/me') {
                  return http.Response(
                    jsonEncode(_meJson()),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.method == 'PUT' &&
                    request.url.path == '/channels/c1/read') {
                  return http.Response(
                    jsonEncode({'last_read_seq': 1, 'unread': 0}),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return _emptyJsonList();
              }),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
          ),
        ),
      );

      // Not pumpAndSettle: see channel_screen_test.dart's own note on why.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      final pressPoint =
          tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
          const Offset(30, 30);
      await tester.longPressAt(pressPoint);
      await tester.pumpAndSettle();

      expect(
        find.text('Delete'),
        findsNothing,
        reason:
            'a DM report or transcript action must gate on DM_BASE, not '
            'the deployment-wide bit the server can never grant here',
      );
      expect(find.text('Pin'), findsNothing);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(
        find.text('Report message'),
        findsOneWidget,
        reason: 'a real, ungated action must still be offered',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );
}
