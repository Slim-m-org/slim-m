// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `NotificationScheduleSection`: turning the schedule on and off, toggling
/// a weekday, switching the off-hours mode, and snoozing - each a real round
/// trip through a mocked `SlimmApi`, the same shape
/// `notification_preference_row_test.dart` already uses.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/device_timezone.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/notification_schedule_section.dart';
import 'package:slimm_app/src/widgets/notification_snooze_section.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// A schedule mid-response: every weekday but Sunday, 09:00-17:00, mentions
/// mode, no allow-lists, no snooze.
Map<String, dynamic> _scheduleJson({
  List<int> weekdays = const [0, 1, 2, 3, 4],
  String offHoursMode = 'mentions',
  int? snoozeUntil,
}) => {
  'timezone': 'America/New_York',
  'days': [
    for (final weekday in weekdays)
      {'weekday': weekday, 'start_minute': 9 * 60, 'end_minute': 17 * 60},
  ],
  'off_hours_mode': offHoursMode,
  'snooze_until': snoozeUntil,
  'allowed_user_ids': <String>[],
  'allowed_channel_ids': <String>[],
};

Future<void> _pump(
  WidgetTester tester,
  Future<http.Response> Function(http.Request request) handler,
) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      deviceTimezoneProvider.overrideWith((ref) async => 'America/New_York'),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/members') return _json(<dynamic>[]);
            return handler(request);
          }),
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
          body: SingleChildScrollView(
            child: Column(
              children: [
                NotificationScheduleSection(),
                NotificationSnoozeSection(),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('never configured shows the toggle off and nothing else', (
    tester,
  ) async {
    await _pump(tester, (request) async {
      if (request.url.path == '/notifications/schedule') {
        return _json({'schedule': null});
      }
      return http.Response('', 404);
    });

    expect(find.text('Notification schedule'), findsOneWidget);
    expect(find.text('Hours'), findsNothing);
    expect(find.text('Outside these hours'), findsNothing);
  });

  testWidgets('turning it on sends a default Monday-Friday schedule', (
    tester,
  ) async {
    Map<String, dynamic>? putBody;
    var configured = false;
    await _pump(tester, (request) async {
      if (request.url.path == '/notifications/schedule') {
        if (request.method == 'PUT') {
          putBody = jsonDecode(request.body) as Map<String, dynamic>;
          configured = true;
          return _json({
            'schedule': _scheduleJson(
              offHoursMode: putBody!['off_hours_mode'] as String,
            ),
          });
        }
        return _json({'schedule': configured ? _scheduleJson() : null});
      }
      return http.Response('', 404);
    });

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!['timezone'], 'America/New_York');
    expect(putBody!['off_hours_mode'], 'mentions');
    final days = (putBody!['days'] as List<dynamic>)
        .map((d) => (d as Map<String, dynamic>)['weekday'] as int)
        .toSet();
    expect(days, {0, 1, 2, 3, 4});
    expect(find.text('Hours'), findsOneWidget);
    expect(find.text('Outside these hours'), findsOneWidget);
    expect(
      find.text(
        'Calls still ring even outside your hours; only chat '
        'notifications follow this schedule.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping a day toggles it out of the schedule', (tester) async {
    Map<String, dynamic>? lastPutBody;
    await _pump(tester, (request) async {
      if (request.url.path == '/notifications/schedule') {
        if (request.method == 'PUT') {
          lastPutBody = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({'schedule': _scheduleJson()});
        }
        return _json({'schedule': _scheduleJson()});
      }
      return http.Response('', 404);
    });
    await tester.tap(find.text('M').first);
    await tester.pumpAndSettle();

    expect(lastPutBody, isNotNull);
    final days = (lastPutBody!['days'] as List<dynamic>)
        .map((d) => (d as Map<String, dynamic>)['weekday'] as int)
        .toSet();
    expect(days, {1, 2, 3, 4}, reason: 'Monday (0) was turned off');
  });

  testWidgets('choosing nothing mode sends it and shows the new choice', (
    tester,
  ) async {
    var mode = 'mentions';
    await _pump(tester, (request) async {
      if (request.url.path == '/notifications/schedule') {
        if (request.method == 'PUT') {
          mode =
              (jsonDecode(request.body)
                      as Map<String, dynamic>)['off_hours_mode']
                  as String;
        }
        return _json({'schedule': _scheduleJson(offHoursMode: mode)});
      }
      return http.Response('', 404);
    });

    await tester.tap(find.text('Outside these hours'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nothing').last);
    await tester.pumpAndSettle();

    expect(mode, 'nothing');
  });

  testWidgets('snoozing for 30m shows the active-snooze row', (tester) async {
    int? snoozeUntil;
    await _pump(tester, (request) async {
      if (request.url.path == '/notifications/schedule/snooze' &&
          request.method == 'PUT') {
        snoozeUntil =
            (jsonDecode(request.body) as Map<String, dynamic>)['until_ms']
                as int;
        return _json({'snooze_until': snoozeUntil});
      }
      if (request.url.path == '/notifications/schedule') {
        return _json({'schedule': _scheduleJson(snoozeUntil: snoozeUntil)});
      }
      return http.Response('', 404);
    });

    await tester.tap(find.text('30m'));
    await tester.pumpAndSettle();

    expect(snoozeUntil, isNotNull);
    expect(find.textContaining('Snoozed until'), findsOneWidget);
    expect(find.text('30m'), findsNothing);
  });

  testWidgets('the snooze buttons sit under their own label, and the calls '
      'caption is secondary text like the other helpers', (tester) async {
    await _pump(tester, (request) async {
      if (request.url.path == '/notifications/schedule') {
        return _json({'schedule': _scheduleJson()});
      }
      return http.Response('', 404);
    });

    final label = tester.getRect(find.text('Snooze notifications for'));
    final first = tester.getRect(find.text('30m'));
    expect(label.right, lessThanOrEqualTo(first.left));
    expect(
      label.center.dy,
      closeTo(first.center.dy, first.height),
      reason: 'the heading leads the same row of buttons',
    );

    final tokens = AppTokens.light;
    final caption = tester.widget<Text>(
      find.textContaining('Calls still ring'),
    );
    expect(caption.style?.color, tokens.textSecondary);
  });
}
