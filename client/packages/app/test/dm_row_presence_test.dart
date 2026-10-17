// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// DmRow used to draw a bare AppAvatar with no presence overlay at all, so a
/// DM peer's online state was invisible in the rail no matter what it was.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Channel _dm(String id, String name, String peerId) => Channel(
  id: id,
  name: name,
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: peerId,
);

ProviderContainer _container() {
  final db = SlimmDatabase(NativeDatabase.memory());
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(db.close);
        return db;
      }),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/voice/roster')) {
              return http.Response(
                jsonEncode({'participants': <Object>[]}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
}

Future<void> _pumpRow(
  WidgetTester tester,
  ProviderContainer container,
  Channel channel,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: DmRow(channel: channel, selected: false)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a known peer\'s live presence reaches the row\'s avatar', (
    tester,
  ) async {
    final channel = _dm('dm-1', 'Priya', 'user-priya');
    final container = _container();
    container.read(presenceControllerProvider.notifier).state = const {
      'user-priya': api.PresenceState.online,
    };

    await _pumpRow(tester, container, channel);

    final avatar = tester.widget<AppAvatar>(find.byType(AppAvatar));
    expect(avatar.status, AppPresence.online);
    container.dispose();
  });

  testWidgets(
    'a peer this session has no presence for yet is unknown, which draws no '
    'dot, rather than offline, which draws a grey ring',
    (tester) async {
      final channel = _dm('dm-1', 'Priya', 'user-priya');
      final container = _container();

      await _pumpRow(tester, container, channel);

      final avatar = tester.widget<AppAvatar>(find.byType(AppAvatar));
      expect(avatar.status, AppPresence.unknown);
      container.dispose();
    },
  );
}
