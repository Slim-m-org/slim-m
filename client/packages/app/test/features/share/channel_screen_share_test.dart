// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share handed to a channel reaches the composer of the real channel screen.
///
/// The handoff widget is tested beside a composer on its own; this is the only
/// test that fails if the screen stops mounting it around its composer.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('the channel screen stages a share handed to its channel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('share-screen-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/holiday.png';
    File(path).writeAsBytesSync(Uint8List(4));

    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);

    var sent = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        mockApiOverride((request) async {
          if (request.method == 'POST' && request.url.path == '/attachments') {
            return _json({
              'id': 'a1',
              'filename': 'holiday.png',
              'content_type': 'image/png',
              'size': 4,
            }, 201);
          }
          if (request.method == 'POST') sent++;
          if (request.method == 'GET' && request.url.path == '/me') {
            return _json({
              'id': 'bob',
              'username': 'bob',
              'display_name': 'Bob',
              'created_at': 0,
              'permissions': 0,
            });
          }
          return _json([]);
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(shareHandoffProvider.notifier).state = (
      channelId: 'c1',
      share: IncomingShare(
        files: [SharedFile(path: path, name: 'holiday.png', length: 4)],
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
        ),
      ),
    );
    for (
      var i = 0;
      i < 400 && find.text('holiday.png').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('holiday.png'), findsOneWidget);
    expect(container.read(shareHandoffProvider), isNull);
    expect(sent, 0, reason: 'a share is staged, never sent');

    // The drift query streams cancel on a zero-duration timer; see the send test.
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
