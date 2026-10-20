// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A select menu on a bot's message: a short single pick opens the anchored
/// menu, a long or multiple pick a sheet, and the choice reaches the bot as
/// the values of one press.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/message_buttons.dart';
import 'package:slimm_app/src/providers/button_presses.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

api.ComponentRow _menu({
  int options = 3,
  int minValues = 1,
  int maxValues = 1,
  bool disabled = false,
}) => api.ComponentRow(
  select: api.MessageSelect(
    customId: 'day',
    placeholder: 'Pick a day',
    minValues: minValues,
    maxValues: maxValues,
    disabled: disabled,
    options: [
      for (var i = 0; i < options; i++)
        api.SelectChoice(label: 'Day $i', value: 'd$i'),
    ],
  ),
);

class _Harness {
  _Harness(this.events, this.requests);

  final StreamController<api.ServerEvent> events;
  final List<Map<String, dynamic>> requests;
}

Future<_Harness> _pump(
  WidgetTester tester,
  api.ComponentRow row, {
  double width = 1280,
  bool unavailable = false,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
              200,
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
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: MessageButtons(
                channelId: 'c1',
                messageId: 'm1',
                rows: [row],
                unavailable: unavailable,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return _Harness(events, requests);
}

void main() {
  testWidgets('a short single pick opens a menu and sends that value', (
    tester,
  ) async {
    final h = await _pump(tester, _menu());
    expect(find.text('Pick a day'), findsOneWidget);

    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();
    expect(find.byType(AppMenuItem), findsNWidgets(3));
    await tester.tap(find.text('Day 1'));
    await tester.pumpAndSettle();

    expect(h.requests.single['custom_id'], 'day');
    expect(h.requests.single['values'], ['d1']);
    await tester.pump(buttonPressTimeout + const Duration(seconds: 1));
  });

  testWidgets('more than eight options is a sheet, not a menu', (tester) async {
    final h = await _pump(tester, _menu(options: 12));
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();

    expect(find.byType(AppMenuItem), findsNothing);
    expect(find.byType(AppListRow), findsWidgets);
    await tester.tap(find.text('Day 9'));
    await tester.pumpAndSettle();

    expect(h.requests.single['values'], ['d9']);
    await tester.pump(buttonPressTimeout + const Duration(seconds: 1));
  });

  testWidgets('a multiple choice waits for its minimum, then sends them all', (
    tester,
  ) async {
    final h = await _pump(tester, _menu(minValues: 2, maxValues: 3));
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();

    AppButton choose() =>
        tester.widget<AppButton>(find.widgetWithText(AppButton, 'Choose'));
    await tester.tap(find.text('Day 0'));
    await tester.pump();
    expect(
      choose().disabled,
      isTrue,
      reason: 'one is under the minimum of two',
    );

    await tester.tap(find.text('Day 2'));
    await tester.pump();
    expect(choose().disabled, isFalse);
    await tester.tap(find.widgetWithText(AppButton, 'Choose'));
    await tester.pumpAndSettle();

    expect(h.requests.single['values'], ['d0', 'd2']);
    await tester.pump(buttonPressTimeout + const Duration(seconds: 1));
  });

  testWidgets('the sheet stops at the maximum', (tester) async {
    await _pump(tester, _menu(maxValues: 2));
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();
    for (final day in ['Day 0', 'Day 1', 'Day 2']) {
      await tester.tap(find.text(day));
      await tester.pump();
    }
    expect(find.byIcon(AppIcons.check), findsNWidgets(2));
  });

  testWidgets('the menu is pending until the bot answers', (tester) async {
    final h = await _pump(tester, _menu());
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(AppMenuItem), findsNothing, reason: 'closed on choose');
    await tester.tap(find.text('Pick a day'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AppMenuItem), findsNothing, reason: 'pending is inert');

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
  });

  testWidgets('silence fails it visibly and a retry sends the same values', (
    tester,
  ) async {
    final h = await _pump(tester, _menu(maxValues: 2));
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day 0'));
    await tester.tap(find.text('Day 1'));
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Choose'));
    await tester.pumpAndSettle();
    await tester.pump(buttonPressTimeout + const Duration(seconds: 1));
    expect(find.byType(AppErrorState), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(h.requests, hasLength(2));
    expect(h.requests.last['values'], ['d0', 'd1']);
    await tester.pump(buttonPressTimeout + const Duration(seconds: 1));
  });

  testWidgets('a disabled menu and a gone bot cannot be opened', (
    tester,
  ) async {
    await _pump(tester, _menu(disabled: true));
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();
    expect(find.byType(AppMenuItem), findsNothing);

    await _pump(tester, _menu(), unavailable: true);
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();
    expect(find.byType(AppMenuItem), findsNothing);
  });

  testWidgets('a menu fits a phone beside its long label', (tester) async {
    await _pump(tester, _menu(), width: 390);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Pick a day'));
    await tester.pumpAndSettle();
    expect(find.text('Day 2'), findsOneWidget);
  });
}
