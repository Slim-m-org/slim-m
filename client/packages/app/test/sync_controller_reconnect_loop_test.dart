// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A socket that drops within seconds of connecting must keep backing off, and
/// coming back to the foreground must not wait out whatever backoff is left.
library;

import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/app_lifecycle.dart';
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

class _NoJitter implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

void main() {
  testWidgets(
    'quick drops back off further each time, and resume skips the wait',
    (tester) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final server = (await tester.runAsync(SyncTestServer.start))!;
      await tester.pump();

      final router = RestRouter()
        ..on('POST', '/sync', (_) => jsonResponse({'scopes': <dynamic>[]}))
        ..on(
          'POST',
          '/auth/ws-ticket',
          (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
        );
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore()),
          storeProvider.overrideWith((ref) async => MessageStore(db)),
          syncControllerProvider.overrideWith(
            (ref) => SyncController(ref, random: _NoJitter()),
          ),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: server.baseUrl,
              session: ref.watch(sessionProvider),
              httpClient: router.build(),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );

      Future<bool> untilState(SyncStatus want, Duration within) async {
        final end = DateTime.now().add(within);
        while (DateTime.now().isBefore(end)) {
          if (container.read(syncControllerProvider) == want) return true;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return container.read(syncControllerProvider) == want;
      }

      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          container.read(syncControllerProvider.notifier);
          container.read(sessionProvider).set(_tokens);
          expect(
            await untilState(SyncStatus.live, const Duration(seconds: 5)),
            isTrue,
          );

          await server.dropSockets();
          expect(
            await untilState(SyncStatus.offline, const Duration(seconds: 2)),
            isTrue,
          );
          expect(
            await untilState(
              SyncStatus.live,
              const Duration(milliseconds: 1600),
            ),
            isTrue,
            reason: 'the first drop retries after one second',
          );

          await server.dropSockets();
          expect(
            await untilState(SyncStatus.offline, const Duration(seconds: 2)),
            isTrue,
          );
          expect(
            await untilState(
              SyncStatus.live,
              const Duration(milliseconds: 1400),
            ),
            isFalse,
            reason:
                'a connection that lasted moments earns no reset: two seconds now',
          );

          final lifecycle = container.read(appLifecycleProvider.notifier);
          lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
          lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(
            await untilState(
              SyncStatus.live,
              const Duration(milliseconds: 800),
            ),
            isTrue,
            reason: 'returning to the foreground reconnects at once',
          );
        });
      } finally {
        container.dispose();
        await tester.pump();
        await tester.runAsync(server.close);
      }
    },
  );

  testWidgets(
    'a resync demand right after connecting backs off, not a tight loop',
    (tester) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final server = (await tester.runAsync(SyncTestServer.start))!;
      await tester.pump();

      var tickets = 0;
      final router = RestRouter()
        ..on('POST', '/sync', (_) => jsonResponse({'scopes': <dynamic>[]}))
        ..on('POST', '/auth/ws-ticket', (_) {
          tickets++;
          return jsonResponse({'ticket': 'tix', 'expires_at': 0});
        });
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore()),
          storeProvider.overrideWith((ref) async => MessageStore(db)),
          syncControllerProvider.overrideWith(
            (ref) => SyncController(ref, random: _NoJitter()),
          ),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: server.baseUrl,
              session: ref.watch(sessionProvider),
              httpClient: router.build(),
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
          for (var i = 0; i < 250; i++) {
            if (container.read(syncControllerProvider) == SyncStatus.live) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(tickets, 1);

          server.pushEvent({'type': 'error', 'message': 'resync'});
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(
            tickets,
            1,
            reason: 'a fresh connection that lags waits its backoff',
          );
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          expect(tickets, 2);
        });
      } finally {
        container.dispose();
        await tester.pump();
        await tester.runAsync(server.close);
      }
    },
  );
}
