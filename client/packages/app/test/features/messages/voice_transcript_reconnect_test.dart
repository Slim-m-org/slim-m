// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A transcript finished while the socket was down is never replayed, so a
/// reconnect rereads every open channel's newest page, and the first connect
/// does not; turning transcripts back on rereads them too.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/providers/mounted_channels.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import '../../support/quick_reconnect.dart';
import '../../support/sync_harness.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _voice(String status) => {
  'id': 'm1',
  'channel_id': 'c1',
  'author_id': 'alice',
  'author_display_name': 'Alice',
  'seq': 1,
  'content': '',
  'created_at': 0,
  'attachments': [
    {
      'id': 'a1',
      'filename': 'voice-message.ogg',
      'content_type': 'audio/ogg',
      'size': 4,
      'transcript': {'status': status, 'text': 'hello'},
    },
  ],
};

class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  String status = 'pending';
  bool transcribe = true;
  int pages = 0;

  late final SlimmDatabase db;
  late final SyncTestServer server;
  late final ProviderContainer container;

  Future<void> start() async {
    db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();
    final router = RestRouter()
      ..on('GET', '/channels/c1/messages', (_) {
        pages++;
        return jsonResponse([_voice(status)]);
      })
      ..on(
        'GET',
        '/version',
        (_) => jsonResponse({
          'name': 'slim-m',
          'version': '1',
          'protocol': 1,
          'transcribe_voice_messages': transcribe,
        }),
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

  Future<void> dropAndReconnect() => tester.runAsync(() async {
    await server.dropSockets();
    for (var i = 0; i < 200; i++) {
      if (container.read(syncControllerProvider) != SyncStatus.live) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await _untilLive();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  VoiceTranscriptStatus? held() => container
      .read(messageExtrasProvider.notifier)
      .extrasFor('m1')
      .attachments
      .firstOrNull
      ?.transcript
      ?.status;

  Future<void> close() async {
    container.dispose();
    await tester.pump();
    await tester.runAsync(server.close);
    await db.close();
  }
}

void main() {
  testWidgets('a reconnect rereads an open channel, so a transcript finished '
      'while down shows', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await rig.connect();
      rig.container.read(mountedChannelsProvider).register('c1');
      rig.container.read(messageExtrasProvider.notifier).applyMessages([
        Message.fromJson(_voice('pending')),
      ]);
      expect(rig.pages, 0, reason: 'the first connect rereads nothing');

      rig.status = 'ready';
      await rig.dropAndReconnect();

      expect(rig.pages, 1);
      expect(rig.held(), VoiceTranscriptStatus.ready);
    } finally {
      await rig.close();
    }
  });

  testWidgets('turning transcripts back on rereads an open channel, whose '
      'messages were read without them', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      rig.transcribe = false;
      await rig.connect();
      rig.container.listen(serverInfoProvider, (_, _) {});
      await tester.runAsync(
        () => rig.container.read(serverInfoProvider.future),
      );
      rig.container.read(mountedChannelsProvider).register('c1');
      rig.container.read(messageExtrasProvider.notifier).applyMessages([
        Message.fromJson({..._voice('pending'), 'attachments': <Object>[]}),
      ]);

      rig.transcribe = true;
      rig.status = 'ready';
      await tester.runAsync(() async {
        rig.server.pushEvent({'type': 'space.settings_changed'});
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });

      expect(rig.pages, 1);
      expect(rig.held(), VoiceTranscriptStatus.ready);
    } finally {
      await rig.close();
    }
  });
}
