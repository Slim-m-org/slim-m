// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message's failure line selects its own failure, so a use on some other
/// message must not rebuild it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/bot_ui_failure.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('a use on another message does not rebuild a shown failure', (
    tester,
  ) async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [
        liveEventsProvider.overrideWithValue(events.stream),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'u1',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 4102444800000,
              ),
            ),
            httpClient: MockClient(
              (request) async => http.Response(
                jsonEncode({'id': 'x', 'created_at': 1}),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    final uses = container.read(botUiUsesProvider.notifier);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: BotUiFailureLine(messageId: 'm1')),
        ),
      ),
    );

    Future<void> use(String messageId) => uses.useMenuEntry(
      channelId: 'c1',
      botId: 'b1',
      entryId: 'translate',
      messageId: messageId,
    );
    unawaited(use('m1'));
    await tester.pump();
    await tester.pump(botUiUseTimeout + const Duration(seconds: 1));
    expect(find.byType(AppErrorState), findsOneWidget);

    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is BotUiFailureLine) rebuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    unawaited(use('m2'));
    await tester.pump();

    expect(rebuilds, 0);
    await tester.pump(botUiUseTimeout + const Duration(seconds: 1));
  });
}
