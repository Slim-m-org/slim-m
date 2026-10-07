// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// DmRow drew initials for every peer because it never handed the avatar an
/// image; a peer with a picture must render it, and one without keeps initials.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/dm_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

// A 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Channel _dm(String peerId) => Channel(
  id: 'dm-$peerId',
  name: 'Nadia',
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

ProviderContainer _container({required bool hasAvatar}) {
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
            if (request.url.path == '/users') {
              return http.Response(
                jsonEncode([
                  {
                    'id': 'user-nadia',
                    'username': 'nadia',
                    'display_name': 'Nadia',
                    'created_at': 0,
                    'avatar_updated_at': hasAvatar ? 1 : null,
                    'roles': <String>[],
                  },
                ]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path.endsWith('/avatar') && hasAvatar) {
              return http.Response.bytes(
                _png,
                200,
                headers: {'content-type': 'image/png'},
              );
            }
            return http.Response('', 404);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
}

Future<void> _pump(WidgetTester tester, {required bool hasAvatar}) async {
  final container = _container(hasAvatar: hasAvatar);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: DmRow(channel: _dm('user-nadia'), selected: false),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a peer with a picture shows it, keeping size and presence', (
    tester,
  ) async {
    await _pump(tester, hasAvatar: true);
    final avatar = tester.widget<AppAvatar>(find.byType(AppAvatar));
    expect(avatar.image, isNotNull);
    expect(avatar.size, AppAvatarSize.s28);
    expect(avatar.status, AppPresence.unknown);
  });

  testWidgets('a peer without a picture keeps initials on the id tint', (
    tester,
  ) async {
    await _pump(tester, hasAvatar: false);
    final avatar = tester.widget<AppAvatar>(find.byType(AppAvatar));
    expect(avatar.image, isNull);
    expect(avatar.tintKey, 'user-nadia');
  });
}
