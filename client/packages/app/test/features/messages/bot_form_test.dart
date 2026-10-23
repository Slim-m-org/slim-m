// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The form a bot opens for a press: it appears wherever the member is, holds
/// a submit until the required fields are filled, and closes when the bot
/// answers the submission.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/messages/providers/bot_forms.dart';
import 'package:slimm_app/src/features/messages/widgets/bot_form_gate.dart';
import 'package:slimm_app/src/features/messages/widgets/bot_form_sheet.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _form = api.BotForm(
  customId: 'remind',
  title: 'Remind me',
  submitLabel: 'Set reminder',
  fields: [
    api.BotFormField(
      customId: 'what',
      label: 'What',
      placeholder: 'Water the plants',
      maxLength: 40,
    ),
    api.BotFormField(
      customId: 'note',
      label: 'Note',
      required: false,
      multiline: true,
      value: 'weekly',
    ),
  ],
);

class _Harness {
  _Harness(this.events, this.requests, this.paths);

  final StreamController<api.ServerEvent> events;
  final List<Map<String, dynamic>> requests;
  final List<String> paths;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  int status = 200,
  double width = 1280,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final requests = <Map<String, dynamic>>[];
  final paths = <String>[];
  final container = ProviderContainer(
    overrides: [
      ...overrides,
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith((ref) {
        final client = testApi(
          (request) async {
            paths.add(request.url.path);
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
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: BotFormGate(child: Center(child: Text('channel'))),
        ),
      ),
    ),
  );
  return _Harness(events, requests, paths);
}

Future<void> _open(WidgetTester tester, _Harness h) async {
  h.events.add(
    const api.InteractionForm(
      interactionId: 'i1',
      channelId: 'c1',
      messageId: 'm1',
      form: _form,
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

AppButton _submit(WidgetTester tester) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, 'Set reminder'));

void main() {
  testWidgets('a form frame opens the form wherever the member is', (
    tester,
  ) async {
    final h = await _pump(tester);
    expect(find.text('Remind me'), findsNothing);
    await _open(tester, h);

    expect(find.text('Remind me'), findsOneWidget);
    expect(find.text('What'), findsOneWidget);
    expect(find.text('Note (optional)'), findsOneWidget);
    expect(find.text('weekly'), findsOneWidget, reason: 'prefilled value');
  });

  testWidgets('submit waits for the required field, then sends every field', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _open(tester, h);
    expect(_submit(tester).disabled, isTrue);

    await tester.enterText(find.byType(TextField).first, 'water plants');
    await tester.pump();
    expect(_submit(tester).disabled, isFalse);
    await tester.tap(find.widgetWithText(AppButton, 'Set reminder'));
    await tester.pump();

    expect(h.paths.single, '/channels/c1/interactions/i1/submit');
    expect(h.requests.single['fields'], {
      'what': 'water plants',
      'note': 'weekly',
    });
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text('Remind me'),
      findsOneWidget,
      reason: 'stays until answered',
    );

    h.events.add(
      api.InteractionAnswered(
        interactionId: h.requests.single['id'] as String,
        channelId: 'c1',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remind me'), findsNothing);
  });

  testWidgets('an answer to some other press leaves the form open', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _open(tester, h);
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Set reminder'));
    await tester.pump();

    h.events.add(
      const api.InteractionAnswered(interactionId: 'other', channelId: 'c1'),
    );
    await tester.pump();
    expect(find.text('Remind me'), findsOneWidget);
    await tester.pump(botFormTimeout + const Duration(seconds: 1));
  });

  testWidgets('silence says so inline, and retry sends it again', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _open(tester, h);
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Set reminder'));
    await tester.pump();
    await tester.pump(botFormTimeout + const Duration(seconds: 1));

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('did not answer'), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget, reason: 'nothing is lost');

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(h.requests, hasLength(2));
    expect(h.requests.last['id'], h.requests.first['id']);
    await tester.pump(botFormTimeout + const Duration(seconds: 1));
  });

  testWidgets('a bot that answers after the timeout still closes the form', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _open(tester, h);
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Set reminder'));
    await tester.pump();
    await tester.pump(botFormTimeout + const Duration(seconds: 1));
    expect(find.textContaining('did not answer'), findsOneWidget);

    h.events.add(
      api.InteractionAnswered(
        interactionId: h.requests.single['id'] as String,
        channelId: 'c1',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remind me'), findsNothing);
  });

  testWidgets(
    'a form arriving in an idle app schedules the frame that shows it',
    (tester) async {
      final h = await _pump(tester);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      h.events.add(
        const api.InteractionForm(
          interactionId: 'i1',
          channelId: 'c1',
          form: _form,
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(tester.binding.hasScheduledFrame, isTrue);
    },
  );

  testWidgets('the form says a bot opened it and where the input goes', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _open(tester, h);
    expect(find.textContaining('opened by a bot'), findsOneWidget);
    expect(find.textContaining('not to slim-m'), findsOneWidget);
  });

  testWidgets('the form names the bot that opened it', (tester) async {
    final h = await _pump(
      tester,
      overrides: [
        userProfileProvider('b1').overrideWith(
          (ref) async => const api.UserProfile(
            id: 'b1',
            username: 'reminders',
            displayName: 'Reminders',
            createdAt: 0,
          ),
        ),
      ],
    );
    h.events.add(
      const api.InteractionForm(
        interactionId: 'i1',
        channelId: 'c1',
        botId: 'b1',
        form: _form,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('opened by Reminders'), findsOneWidget);
  });

  testWidgets('a form the server no longer has is explained inline', (
    tester,
  ) async {
    final h = await _pump(tester, status: 404);
    await _open(tester, h);
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Set reminder'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('no longer available'), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget);
  });

  testWidgets('the form fits a phone', (tester) async {
    final h = await _pump(tester, width: 390);
    await _open(tester, h);
    expect(find.text('Remind me'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.widgetWithText(AppButton, 'Set reminder'));
    expect(size.height, greaterThanOrEqualTo(AppSizes.rowTouch));
  });

  test('forms wait in the provider until the gate takes them', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    container.read(botFormsProvider);
    events.add(
      const api.InteractionForm(
        interactionId: 'i1',
        channelId: 'c1',
        form: _form,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final taken = container.read(botFormsProvider.notifier).takeAll();
    expect(taken.single.interactionId, 'i1');
    expect(container.read(botFormsProvider), isEmpty);
  });
}
