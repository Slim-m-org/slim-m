// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's buttons: what each style looks like, the pending state after a
/// press, and the persistent failure when the bot never answers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/button_presses.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/message_buttons.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _rows = [
  api.ComponentRow(
    buttons: [
      api.MessageButton(
        label: 'Hit',
        style: api.ComponentButtonStyle.primary,
        customId: 'hit',
      ),
      api.MessageButton(
        label: 'Stand',
        style: api.ComponentButtonStyle.secondary,
        customId: 'stand',
      ),
      api.MessageButton(
        label: 'Fold',
        style: api.ComponentButtonStyle.danger,
        customId: 'fold',
      ),
      api.MessageButton(
        label: 'Rules',
        style: api.ComponentButtonStyle.link,
        url: 'https://example.com/rules',
      ),
      api.MessageButton(
        label: 'Double',
        style: api.ComponentButtonStyle.secondary,
        customId: 'double',
        disabled: true,
      ),
    ],
  ),
];

class _Harness {
  _Harness(this.container, this.events, this.requests);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final List<Map<String, dynamic>> requests;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  int status = 200,
  bool unavailable = false,
}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final requests = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith((ref) {
        final client = testApi(
          (request) async {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({'id': requests.last['id'], 'created_at': 1}),
              status,
              headers: {'content-type': 'application/json'},
            );
          },
          session: api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'u1',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 4102444800000,
            ),
          ),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(buttonPressesProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: MessageButtons(
              channelId: 'c1',
              messageId: 'm1',
              rows: _rows,
              unavailable: unavailable,
            ),
          ),
        ),
      ),
    ),
  );
  return _Harness(container, events, requests);
}

void main() {
  testWidgets('every style renders, and a link carries the external icon', (
    tester,
  ) async {
    await _pump(tester);
    for (final label in ['Hit', 'Stand', 'Fold', 'Rules', 'Double']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byIcon(AppIcons.externalLink), findsOneWidget);
  });

  testWidgets('a link shows where it really goes, whatever its label says', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('Rules'), findsOneWidget);
  });

  testWidgets('a press shows pending, then clears when the bot answers', (
    tester,
  ) async {
    final h = await _pump(tester);
    await tester.tap(find.text('Hit'));
    await tester.pump();

    expect(h.requests.single['custom_id'], 'hit');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text('Stand'),
      findsOneWidget,
      reason: 'the row must not reflow',
    );

    h.events.add(
      api.InteractionAnswered(
        interactionId: h.requests.single['id'] as String,
        channelId: 'c1',
        messageId: 'm1',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(AppErrorState), findsNothing);
  });

  testWidgets('silence fails the button visibly, and retry presses again', (
    tester,
  ) async {
    final h = await _pump(tester);
    await tester.tap(find.text('Hit'));
    await tester.pump();
    await tester.pump(buttonPressTimeout + const Duration(seconds: 1));

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('did not answer'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(h.requests.length, 2);
    expect(h.requests.first['id'], isNot(h.requests.last['id']));
    expect(find.byType(AppErrorState), findsNothing);
    await tester.pump(buttonPressTimeout + const Duration(seconds: 1));
  });

  testWidgets('a refused press explains itself at once', (tester) async {
    await _pump(tester, status: 404);
    await tester.tap(find.text('Stand'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('no longer available'), findsOneWidget);
  });

  testWidgets('a disabled button and a gone bot cannot be pressed', (
    tester,
  ) async {
    final h = await _pump(tester);
    await tester.tap(find.text('Double'));
    await tester.pump();
    expect(h.requests, isEmpty);
  });

  testWidgets('every button is dead once the bot is gone', (tester) async {
    final h = await _pump(tester, unavailable: true);
    await tester.tap(find.text('Hit'));
    await tester.pump();
    expect(h.requests, isEmpty);
  });

  test('a components frame replaces the list and a REST page can clear it', () {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);
    api.Message build(String content, {bool buttons = false}) =>
        api.Message.fromJson({
          'id': 'm1',
          'channel_id': 'c1',
          'author_id': 'bot',
          'author_display_name': 'Bot',
          'seq': 1,
          'content': content,
          'created_at': 1,
          if (buttons)
            'components': [
              {
                'buttons': [
                  {'label': 'Hit', 'style': 'primary', 'custom_id': 'hit'},
                ],
              },
            ],
        });
    final message = build('x', buttons: true);
    extras.applyMessage(message);
    expect(extras.extrasFor('m1').components, hasLength(1));

    final bare = build('edited');
    extras.applyMessage(bare);
    expect(
      extras.extrasFor('m1').components,
      hasLength(1),
      reason: 'an edit frame carries none and must not clear them',
    );

    extras.applyMessages([bare]);
    expect(
      extras.extrasFor('m1').components,
      isEmpty,
      reason: 'a REST fetch is authoritative',
    );

    extras.applyMessage(message);
    events.add(
      const api.MessageComponentsChanged(
        channelId: 'c1',
        messageId: 'm1',
        components: [],
      ),
    );
    return Future<void>.delayed(Duration.zero).then((_) {
      expect(extras.extrasFor('m1').components, isEmpty);
    });
  });
}
