// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the roster does once the socket is live again after a drop: a profile
/// edit or a presence change made while it was down is never replayed, so the
/// roster, its live overrides and its presence are asked for again, and only then.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';
import '../../support/quick_reconnect.dart';
import '../../support/sync_harness.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _member(String id, {String? status}) => {
  'id': id,
  'username': id,
  'display_name': id,
  'status_text': status,
  'created_at': 0,
};

/// A sync controller over a real socket server, with a roster and presence
/// route whose requests are recorded.
class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  List<Map<String, Object?>> roster = [_member('u1'), _member('u2')];
  int rosterPages = 0;
  final presenceAsked = <List<String>>[];

  late final SlimmDatabase db;
  late final SyncTestServer server;
  late final ProviderContainer container;

  Future<void> start() async {
    db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();
    final router = RestRouter()
      ..on('GET', '/members', (_) {
        rosterPages++;
        return jsonResponse(roster);
      })
      ..on('GET', '/presence', (request) {
        presenceAsked.add(request.url.queryParameters['ids']!.split(','));
        return jsonResponse(<Object>[]);
      })
      ..on('GET', '/channels', (_) => jsonResponse(<dynamic>[]))
      ..on('POST', '/sync', (_) => jsonResponse({'scopes': <dynamic>[]}))
      ..on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      );
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore()),
        storeProvider.overrideWith((ref) async => store),
        quickReconnect,
        apiProvider.overrideWith((ref) {
          final client = SlimmApi(
            baseUrl: server.baseUrl,
            session: ref.watch(sessionProvider),
            httpClient: router.build(),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }

  Future<void> _untilLive() async {
    for (var i = 0; i < 200; i++) {
      if (container.read(syncControllerProvider) == SyncStatus.live) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> connect() => tester.runAsync(() async {
    container.read(syncControllerProvider.notifier);
    container.read(sessionProvider).set(_tokens);
    await _untilLive();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  Future<void> dropAndReconnect() => tester.runAsync(() async {
    await server.dropSockets();
    for (var i = 0; i < 200; i++) {
      if (container.read(syncControllerProvider) != SyncStatus.live) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await _untilLive();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  Future<void> close() async {
    container.dispose();
    await tester.pump();
    await tester.runAsync(server.close);
    await db.close();
  }
}

void main() {
  testWidgets('a reconnect drops a live edit and re-pages the roster it was '
      'laid over', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await rig.connect();
      rig.container.listen(membersProvider, (_, __) {});
      rig.container.listen(memberProfileOverridesProvider, (_, __) {});
      await tester.runAsync(() => rig.container.read(membersProvider.future));
      rig.container
          .read(memberProfileOverridesProvider.notifier)
          .applyKnown(
            UserProfile.fromJson(_member('u1', status: 'in a meeting')),
          );
      expect(rig.container.read(memberProfileOverridesProvider), isNotEmpty);
      expect(rig.rosterPages, 1);
      rig.roster = [_member('u1', status: 'free')];

      await rig.dropAndReconnect();

      expect(rig.container.read(memberProfileOverridesProvider), isEmpty);
      expect(rig.rosterPages, 2);
      final roster = await tester.runAsync(
        () => rig.container.read(membersProvider.future),
      );
      expect(roster!.single.statusText, 'free');
    } finally {
      await rig.close();
    }
  });

  testWidgets('the first connect leaves a loaded roster alone', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await tester.runAsync(() async {
        rig.container.read(sessionProvider).set(_tokens);
        rig.container.listen(membersProvider, (_, __) {});
        await rig.container.read(membersProvider.future);
      });

      await rig.connect();

      expect(rig.rosterPages, 1);
    } finally {
      await rig.close();
    }
  });

  testWidgets('a rebuilt roster asks presence only for members not yet '
      'seeded, and a reconnect asks for everyone again', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await rig.connect();
      rig.container.listen(presenceSeedProvider(null), (_, __) {});
      await tester.runAsync(
        () => rig.container.read(presenceSeedProvider(null).future),
      );
      expect(rig.presenceAsked, [
        ['u1', 'u2'],
      ]);

      rig.roster = [_member('u1'), _member('u2'), _member('u3')];
      await tester.runAsync(() async {
        rig.container.invalidate(membersProvider);
        await rig.container.read(presenceSeedProvider(null).future);
      });
      expect(rig.presenceAsked, hasLength(2));
      expect(rig.presenceAsked.last, ['u3']);

      await rig.dropAndReconnect();
      await tester.runAsync(
        () => rig.container.read(presenceSeedProvider(null).future),
      );

      expect(rig.presenceAsked.last, ['u1', 'u2', 'u3']);
    } finally {
      await rig.close();
    }
  });

  test(
    'an older lookup that answers last cannot overwrite a newer one',
    () async {
      final events = StreamController<ServerEvent>.broadcast();
      addTearDown(events.close);
      final firstAnswer = Completer<http.Response>();
      var asked = 0;
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(events.stream),
          mockApiOverride((request) async {
            asked++;
            if (asked == 1) return firstAnswer.future;
            return http.Response(
              jsonEncode(_member('u1', status: 'newer')),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(memberProfileOverridesProvider, (_, __) {});

      events.add(const ProfileChanged(userId: 'u1'));
      await pumpEventQueue();
      events.add(const ProfileChanged(userId: 'u1'));
      await pumpEventQueue();
      String? status() =>
          container.read(memberProfileOverridesProvider)['u1']?.statusText;
      expect(status(), 'newer');

      firstAnswer.complete(
        http.Response(
          jsonEncode(_member('u1', status: 'older')),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await pumpEventQueue();

      expect(status(), 'newer');
    },
  );
}
