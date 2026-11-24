// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A thread opened without ThreadScreen, as a notification tap does, still
/// drops its cached rows once the server masks it from this account.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/screens/conversation_pane.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../settings/home_shell_harness.dart';

http.Response _parent({required bool masked}) => http.Response(
  jsonEncode({
    'parent_channel_id': masked ? null : 'c1',
    'parent_channel_name': masked ? null : 'general',
    'parent_message_id': masked ? null : 'p1',
    'parent_content': null,
    'parent_deleted': false,
    'parent_author_id': null,
    'parent_author_display_name': null,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

Future<(MessageStore, Future<void> Function())> _open(
  WidgetTester tester, {
  required bool masked,
}) async {
  final s = setup(
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/thread-parent')) {
        return _parent(masked: masked);
      }
      return http.Response(
        '[]',
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
    signedIn: true,
    extraOverrides: [initialSyncCompleteProvider.overrideWith((ref) => true)],
  );
  final store = await tester.runAsync(
    () => s.container.read(storeProvider.future),
  );
  await store!.upsertChannels([
    const api.Channel(
      id: 't1',
      name: 'thread',
      kind: 'text',
      createdAt: 0,
      parentMessageId: 'p1',
    ),
  ]);
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: s.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ConversationPane(channelId: 't1')),
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  return (store, () => teardown(tester, s.container, s.db));
}

void main() {
  testWidgets('a masked thread loses its cached row', (tester) async {
    final (store, close) = await _open(tester, masked: true);

    expect(await tester.runAsync(() => store.channelRow('t1')), isNull);
    await close();
  });

  testWidgets('a readable thread keeps its row', (tester) async {
    final (store, close) = await _open(tester, masked: false);

    expect(await tester.runAsync(() => store.channelRow('t1')), isNotNull);
    await close();
  });
}
