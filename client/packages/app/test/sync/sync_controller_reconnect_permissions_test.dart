// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the caller may do, once the socket is live again after a drop: a role
/// change, a timeout or an ownership hand-off made while it was down arrives as
/// a frame nobody replays, so `/me` and the channel permissions are asked for
/// again, once.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import '../support/quick_reconnect.dart';
import '../support/sync_harness.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A sync controller over a real socket server whose `/me` and channel
/// permissions the test changes while the socket is down.
class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  int permissions = Perm.viewChannel | Perm.sendMessages;
  int channelPermissions = Perm.viewChannel | Perm.sendMessages;
  bool isOwner = false;
  int meFetches = 0;

  late final SlimmDatabase db;
  late final SyncTestServer server;
  late final ProviderContainer container;

  Map<String, Object?> get _me => {
    'id': 'self',
    'username': 'self',
    'display_name': 'Self',
    'created_at': 0,
    'permissions': permissions,
    'is_owner': isOwner,
    'top_role_position': 1,
  };

  Future<void> start() async {
    db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();
    final router = RestRouter()
      ..on('GET', '/me', (_) {
        meFetches++;
        return jsonResponse(_me);
      })
      ..on(
        'GET',
        '/channels/c1/permissions',
        (_) => jsonResponse({'permissions': channelPermissions}),
      )
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

  /// Mounts what the screens watch and waits for each first answer.
  Future<void> watchPermissions() => tester.runAsync(() async {
    container.listen(myPermissionsProvider, (_, __) {});
    container.listen(roleLadderProvider, (_, __) {});
    container.listen(myChannelPermissionsProvider('c1'), (_, __) {});
    await container.read(meProvider.future);
    await container.read(channelPermissionsProvider('c1').future);
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
  testWidgets('a reconnect after a server-side role change shows the new '
      'permissions', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await rig.connect();
      await rig.watchPermissions();
      expect(rig.container.read(myPermissionsProvider), rig.permissions);
      expect(rig.container.read(roleLadderProvider).isOwner, isFalse);
      final fetchesBefore = rig.meFetches;

      rig.permissions |= Perm.manageMessages;
      rig.channelPermissions |= Perm.manageMessages;
      await rig.dropAndReconnect();

      expect(rig.meFetches, fetchesBefore + 1, reason: 'asked again, once');
      expect(
        rig.container.read(myPermissionsProvider),
        Perm.viewChannel | Perm.sendMessages | Perm.manageMessages,
      );
      expect(
        rig.container.read(myChannelPermissionsProvider('c1')),
        Perm.viewChannel | Perm.sendMessages | Perm.manageMessages,
      );
    } finally {
      await rig.close();
    }
  });

  testWidgets('a reconnect after an ownership hand-off puts the heir on top '
      'of the ladder', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await rig.connect();
      await rig.watchPermissions();

      rig.isOwner = true;
      await rig.dropAndReconnect();

      expect(rig.container.read(roleLadderProvider).isOwner, isTrue);
      expect(rig.container.read(myPermissionsProvider), Perm.all);
    } finally {
      await rig.close();
    }
  });

  testWidgets('the first connect leaves a loaded /me alone', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await tester.runAsync(() async {
        rig.container.read(sessionProvider).set(_tokens);
      });
      await rig.watchPermissions();
      final fetchesBefore = rig.meFetches;

      await rig.connect();

      expect(rig.meFetches, fetchesBefore);
    } finally {
      await rig.close();
    }
  });
}
