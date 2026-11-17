// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Making a voice lobby from the create-channel sheet (decision 0065): the
/// Lobby toggle shows for voice only and sends `creates_rooms` on create.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_actions.dart';
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

const _lobbyCopy =
    'Each person who joins gets their own room, removed when it empties.';

Finder _lobbyToggle() => find.byWidgetPredicate(
  (w) => w is AppToggle && w.semanticLabel == 'Make this a lobby',
);

Future<List<Map<String, dynamic>>> _openSheet(WidgetTester tester) async {
  final bodies = <Map<String, dynamic>>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWith(
          (ref) => testApi((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('{"error":"nope"}', 400);
          }, session: api.SessionStore(tokens: _tokens)),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showCreateChannelSheet(context, initialKind: 'text'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await pumpFrames(tester, frames: 30);
  await tester.enterText(
    find.byWidgetPredicate(
      (w) => w is AppInput && w.placeholder == 'Channel name',
    ),
    'join to talk',
  );
  await tester.pump();
  return bodies;
}

Future<void> _submit(
  WidgetTester tester,
  List<Map<String, dynamic>> bodies,
) async {
  await tester.tap(find.text('Create channel'));
  await waitUntil(tester, () => bodies.isNotEmpty, reason: 'nothing was sent');
}

void main() {
  testWidgets('choosing Voice offers Lobby, and it is sent on create', (
    tester,
  ) async {
    final bodies = await _openSheet(tester);
    expect(_lobbyToggle(), findsNothing, reason: 'a text channel has none');

    await tester.tap(find.text('Voice'));
    await pumpFrames(tester, frames: 30);
    expect(find.text('Lobby'), findsOneWidget);
    expect(find.text(_lobbyCopy), findsOneWidget);

    await tester.tap(_lobbyToggle());
    await pumpFrames(tester, frames: 30);
    await _submit(tester, bodies);

    expect(bodies.single['kind'], 'voice');
    expect(bodies.single['creates_rooms'], isTrue);
  });

  testWidgets('switching back to Text drops the lobby', (tester) async {
    final bodies = await _openSheet(tester);
    await tester.tap(find.text('Voice'));
    await pumpFrames(tester, frames: 30);
    await tester.tap(_lobbyToggle());
    await pumpFrames(tester, frames: 30);
    await tester.tap(find.text('Text'));
    await pumpFrames(tester, frames: 30);
    await _submit(tester, bodies);

    expect(bodies.single['kind'], 'text');
    expect(bodies.single.containsKey('creates_rooms'), isFalse);
  });

  test(
    'an older server that ignores the field gets it set afterwards',
    () async {
      final requests = <String>[];
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          storeProvider.overrideWith((ref) async => MessageStore(db)),
          mockApiOverride((request) async {
            requests.add('${request.method} ${request.url.path}');
            final patched = request.method == 'PATCH';
            return http.Response(
              jsonEncode({
                'id': 'lobby',
                'name': 'join to talk',
                'kind': 'voice',
                'created_at': 0,
                'creates_rooms': patched,
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      final created = await container
          .read(channelActionsProvider)
          .createChannel(
            name: 'join to talk',
            kind: 'voice',
            createsRooms: true,
          );

      expect(requests, ['POST /channels', 'PATCH /channels/lobby']);
      expect(created.createsRooms, isTrue);
    },
  );
}
