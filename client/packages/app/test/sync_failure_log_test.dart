// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sync connect that fails reaches the in-app debug log under the `sync` tag.
///
/// It used to vanish into `catch (_)`, so a bug report from a phone with no
/// terminal said "Offline, retrying" and nothing else. Driven through the real
/// [SyncController] against a client whose transport refuses.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import 'support/sync_harness.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'secret-access',
  refreshToken: 'secret-refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('a refused connect is logged as an offline sync failure', (
    tester,
  ) async {
    final log = DebugLog();
    api.AppLog.install(log);
    addTearDown(() => api.AppLog.install(null));
    final server = (await tester.runAsync(SyncTestServer.start))!;
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
            httpClient: MockClient(
              (_) async => throw http.ClientException('connection refused'),
            ),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );

    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        container.read(syncControllerProvider.notifier);
        container.read(sessionProvider).set(_tokens);
        for (var i = 0; i < 100; i++) {
          if (log.state.any((e) => e.source == api.LogTag.sync)) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });

      final entry = log.state.firstWhere((e) => e.source == api.LogTag.sync);
      expect(entry.level, DiagnosticSeverity.warning);
      expect(entry.message, contains('connect to the server'));
      expect(entry.context['kind'], 'offline');
      expect(log.asReport(), isNot(contains('secret-access')));
    } finally {
      container.dispose();
      await tester.pump();
      await tester.runAsync(server.close);
    }
  });
}
