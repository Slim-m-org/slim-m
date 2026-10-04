// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's controls in a call: shown only while that bot is on the call, sent
/// as an interaction, and reporting a refusal or silence as a persistent line.
/// See docs/decisions/0045-bot-contributed-ui.md.
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
import 'package:slimm_app/src/widgets/bot_call_controls.dart';
import 'package:slimm_design_system/design_system.dart';

const _jellyfin = api.ChannelBotUi(
  botUserId: 'jelly',
  botUsername: 'jellyfin',
  botDisplayName: 'Jellyfin',
  messageMenu: [],
  callControls: [
    api.BotUiEntry(id: 'prev', label: 'Previous', icon: 'skip_previous'),
    api.BotUiEntry(id: 'pause', label: 'Pause', icon: 'pause'),
    api.BotUiEntry(id: 'skip', label: 'Skip', icon: 'skip_next'),
    api.BotUiEntry(id: 'stop', label: 'Stop', icon: 'stop'),
  ],
);

const _quiet = api.ChannelBotUi(
  botUserId: 'quiet',
  botUsername: 'quiet',
  botDisplayName: 'Quiet',
  messageMenu: [api.BotUiEntry(id: 'x', label: 'X')],
  callControls: [],
);

Future<
  ({ProviderContainer container, StreamController<api.ServerEvent> events})
>
_pump(
  WidgetTester tester,
  List<Map<String, dynamic>> requests, {
  double width = 360,
  int status = 200,
}) async {
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
          httpClient: MockClient((request) async {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({'id': requests.last['id'], 'created_at': 1}),
              status,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(botUiUsesProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: width,
              child: BotCallControls(
                channelId: 'call-1',
                groups: botCallGroups(
                  [_jellyfin, _quiet],
                  {'me', 'jelly', 'quiet'},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return (container: container, events: events);
}

void main() {
  group('botCallGroups', () {
    test('only a bot that is on the call and offers controls is shown', () {
      expect(botCallGroups([_jellyfin, _quiet], {'me', 'jelly'}), hasLength(1));
      expect(botCallGroups([_jellyfin, _quiet], {'me', 'quiet'}), isEmpty);
      expect(botCallGroups([_jellyfin], <String>{}), isEmpty);
    });
  });

  testWidgets('controls sit under the bot name and badge', (tester) async {
    await _pump(tester, []);
    expect(find.text('Jellyfin'), findsOneWidget);
    expect(find.text('BOT'), findsOneWidget);
    for (final label in ['Previous', 'Pause', 'Skip', 'Stop']) {
      expect(find.byTooltip(label), findsOneWidget);
      expect(find.text(label), findsNothing, reason: 'icon chips');
    }
    expect(find.byIcon(AppIcons.pause), findsOneWidget);
    expect(find.text('Quiet'), findsNothing);
  });

  testWidgets('a phone width wraps the row instead of overflowing', (
    tester,
  ) async {
    await _pump(tester, [], width: 240);
    expect(tester.takeException(), isNull);
    final strip = tester.getRect(find.byType(BotCallControls));
    final stop = tester.getRect(find.byTooltip('Stop'));
    expect(strip.width, lessThanOrEqualTo(240));
    expect(stop.right, lessThanOrEqualTo(strip.right));
    expect(
      stop.top,
      greaterThan(tester.getRect(find.byTooltip('Previous')).top),
      reason: 'four chips beside the name cannot share one 240 line',
    );
  });

  testWidgets('a press sends the control and clears when the bot answers', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final h = await _pump(tester, requests);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();

    expect(requests.single['surface'], 'call_control');
    expect(requests.single['entry_id'], 'pause');
    expect(requests.single.containsKey('message_id'), isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('Skip'), findsOneWidget, reason: 'no reflow');

    h.events.add(
      api.InteractionAnswered(
        interactionId: requests.single['id'] as String,
        channelId: 'call-1',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(AppErrorState), findsNothing);
  });

  testWidgets('a refused press says why, in place, and can be retried', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    await _pump(tester, requests, status: 403);
    await tester.tap(find.byTooltip('Skip'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('need you to be on the call'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(requests.length, 2);
  });

  testWidgets('silence fails visibly after the timeout', (tester) async {
    await _pump(tester, []);
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();
    await tester.pump(botUiUseTimeout + const Duration(seconds: 1));
    expect(find.textContaining('did not answer'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.byType(AppErrorState), findsNothing);
  });
}
