// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class Posted {
  final List<Map<String, dynamic>> bodies = [];
}

/// [messagePost] decides the answer to POST /channels/c1/messages.
Future<ProviderContainer> pumpChannel(
  WidgetTester tester,
  Posted posted, {
  required Future<http.Response> Function(http.Request) messagePost,
  String channelId = 'c1',
}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    api.Channel(id: channelId, name: 'general', kind: 'text', createdAt: 0),
  ]);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride((request) async {
        final p = request.url.path;
        if (request.method == 'POST' && p == '/attachments') {
          return http.Response(
            jsonEncode({
              'id': 'a1',
              'filename': request.url.queryParameters['filename'] ?? 'x',
              'content_type': 'image/png',
              'size': 4,
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && p == '/channels/$channelId/messages') {
          posted.bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return messagePost(request);
        }
        if (request.method == 'GET' && p == '/me') {
          return http.Response(
            jsonEncode({
              'id': 'bob',
              'username': 'bob',
              'display_name': 'Bob',
              'created_at': 0,
              'permissions': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PUT' && p == '/channels/$channelId/read') {
          return http.Response(
            jsonEncode({'last_read_seq': 1, 'unread': 0}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode([]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(
          Brightness.light,
          AppTokens.light,
        ).copyWith(platform: TargetPlatform.linux),
        home: Scaffold(body: ChannelScreen(channelId: channelId)),
      ),
    ),
  );
  await flush(tester);
  return container;
}

http.Response okMessage(http.Request r) {
  final b = jsonDecode(r.body) as Map<String, dynamic>;
  return http.Response(
    jsonEncode({
      'id': b['id'],
      'channel_id': 'c1',
      'author_id': 'bob',
      'content': b['content'] ?? '',
      'seq': 1,
      'created_at': 1000,
    }),
    201,
    headers: {'content-type': 'application/json'},
  );
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}
