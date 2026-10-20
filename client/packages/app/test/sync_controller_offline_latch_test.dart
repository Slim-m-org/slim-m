// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [hasFailedSinceLiveProvider] is the latch `MobileBootGate` and the
/// connection indicators read instead of the raw, flip-flopping
/// [SyncStatus]; this pins the two writes [SyncController.start] itself
/// makes to it, against a real failing then recovering connection, rather
/// than a test-only stub asserting its own value back at itself.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import 'support/sync_harness.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets(
    'a failed connect latches the flag, a retry that also fails leaves it '
    'latched, and reaching live clears it',
    (tester) async {
      final server = (await tester.runAsync(SyncTestServer.start))!;
      var connected = false;
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore()),
          storeProvider.overrideWith((ref) async => MessageStore(db)),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: server.baseUrl,
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (!connected) {
                  throw http.ClientException('connection refused');
                }
                if (request.url.path == '/auth/ws-ticket') {
                  return jsonResponse({'ticket': 'tix', 'expires_at': 0});
                }
                return jsonResponse(const <dynamic>[]);
              }),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );

      try {
        await tester.pumpWidget(const SizedBox.shrink());

        await tester.runAsync(() async {
          final notifier = container.read(syncControllerProvider.notifier);
          container.read(sessionProvider).set(_tokens);

          for (var i = 0; i < 100; i++) {
            if (container.read(hasFailedSinceLiveProvider)) break;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(
            container.read(hasFailedSinceLiveProvider),
            isTrue,
            reason: "the constructor's own auto-start already failed once",
          );

          // A second attempt while still down: still latched, not re-armed.
          await notifier.start();
          expect(container.read(syncControllerProvider), SyncStatus.offline);
          expect(container.read(hasFailedSinceLiveProvider), isTrue);

          // The server "comes up": the next attempt reaches SyncStatus.live.
          connected = true;
          await notifier.start();
          expect(container.read(syncControllerProvider), SyncStatus.live);
          expect(
            container.read(hasFailedSinceLiveProvider),
            isFalse,
            reason: 'a real reconnect clears the latch for the next drop',
          );
        });
      } finally {
        container.dispose();
        await tester.pump();
        await tester.runAsync(server.close);
      }
    },
  );
}
