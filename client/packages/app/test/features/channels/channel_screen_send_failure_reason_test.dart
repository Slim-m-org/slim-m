// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A send the server refuses has to say why, driven through the real screen.
///
/// The defect this pins: `sendOptimistically` used to catch
/// `api.ApiException` and call `store.markFailed(id)` with nothing else, so
/// a message rejected for being over the character limit sat in the
/// transcript with only "Retry" - and retrying resent the exact same content,
/// failing identically forever with no visible reason. This drives a real
/// send through `ChannelScreen`, has the mocked server answer 400 the way the
/// real one does for an over-limit message, and asserts the failed row names
/// the refusal rather than just offering to try again.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../composer/composer_harness.dart' show sendButton;
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A frame count rather than `pumpAndSettle`: `AppIconButton`'s hover
/// machinery keeps a frame scheduled forever in this environment, so settling
/// never returns.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets(
    'a message the server refuses for being too long shows why, not just Retry',
    (tester) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      await store.upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          storeProvider.overrideWith((ref) async => store),
          syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
          mockApiOverride((request) async {
            if (request.method == 'POST' &&
                request.url.path == '/channels/c1/messages') {
              return http.Response(
                jsonEncode({
                  'error':
                      'message is 37 characters over the '
                      '4000-character limit',
                }),
                400,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' && request.url.path == '/me') {
              return http.Response(
                jsonEncode({
                  'id': 'bob',
                  'username': 'bob',
                  'display_name': 'Bob',
                  'created_at': 0,
                  'permissions': 0,
                }),
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
            // Members, pins and the extras fetch: an empty list answers all of them.
            return http.Response(
              jsonEncode([]),
              200,
              headers: {'content-type': 'application/json'},
            );
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
      await _flush(tester);

      await tester.enterText(find.byType(TextField), 'a very long message');
      await _flush(tester);
      await tester.tap(sendButton);
      await _flush(tester);

      expect(
        find.textContaining('37 characters over the 4000-character limit'),
        findsOneWidget,
        reason:
            'a rejected send must name the refusal, not leave the user '
            'guessing why every retry fails the same way',
      );

      // Unmount deliberately: teardown checks for pending timers first.
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );
}
