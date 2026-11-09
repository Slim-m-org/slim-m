// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Editing the notification schedule quickly, keeping each day's own window,
/// and failing cleanly when the device cannot name its time zone.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/device_timezone.dart';
import 'package:slimm_app/src/features/settings/widgets/notification_schedule_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// A server holding one schedule, replaced by each PUT and recording them.
class _Server {
  _Server(this.days);

  List<Map<String, dynamic>> days;
  final puts = <List<Map<String, dynamic>>>[];

  /// Holds the next PUT's answer until released, to land a tap mid-flight.
  Completer<void>? hold;

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path != '/notifications/schedule') {
      return http.Response('', 404);
    }
    if (request.method == 'PUT') {
      final gate = hold;
      hold = null;
      if (gate != null) await gate.future;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      days = [for (final d in body['days'] as List) d as Map<String, dynamic>];
      puts.add(days);
    }
    return _json({
      'schedule': {
        'timezone': 'America/New_York',
        'days': days,
        'off_hours_mode': 'mentions',
        'snooze_until': null,
        'allowed_user_ids': <String>[],
        'allowed_channel_ids': <String>[],
      },
    });
  }
}

Map<String, dynamic> _day(int weekday, int startHour, int endHour) => {
  'weekday': weekday,
  'start_minute': startHour * 60,
  'end_minute': endHour * 60,
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Server server, {
  Future<String> Function()? timezone,
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      deviceTimezoneProvider.overrideWith(
        (ref) => (timezone ?? () async => 'America/New_York')(),
      ),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: NotificationScheduleSection()),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Set<int> _weekdays(List<Map<String, dynamic>> days) => {
  for (final d in days) d['weekday'] as int,
};

void main() {
  testWidgets('taps made while a save is in flight stack instead of '
      'overwriting each other', (tester) async {
    final server = _Server([for (var i = 0; i < 5; i++) _day(i, 9, 17)]);
    await _pump(tester, server);

    final gate = Completer<void>();
    server.hold = gate;
    await tester.tap(find.bySemanticsLabel('Monday, on'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Tuesday, on'));
    await tester.pump();
    gate.complete();
    await _settle(tester);

    expect(_weekdays(server.puts.last), {2, 3, 4});
    expect(_weekdays(server.days), {2, 3, 4});
    expect(find.bySemanticsLabel('Monday, off'), findsOneWidget);
    expect(find.bySemanticsLabel('Tuesday, off'), findsOneWidget);
  });

  testWidgets('turning a day on keeps the other days on their own windows', (
    tester,
  ) async {
    final server = _Server([_day(0, 9, 17), _day(1, 10, 14)]);
    await _pump(tester, server);

    await tester.tap(find.bySemanticsLabel('Wednesday, off'));
    await _settle(tester);

    expect(server.puts.single, [
      _day(0, 9, 17),
      _day(1, 10, 14),
      _day(2, 9, 17),
    ]);
  });

  testWidgets('a device that cannot name its time zone fails in words, not '
      'silently', (tester) async {
    final server = _Server([_day(0, 9, 17)]);
    await _pump(
      tester,
      server,
      timezone: () async => throw StateError('no tz'),
    );

    await tester.tap(find.bySemanticsLabel('Tuesday, off'));
    await _settle(tester);

    expect(server.puts, isEmpty);
    expect(
      find.text(
        'Could not update your notification schedule. This device did not '
        'say which time zone it is in.',
      ),
      findsOneWidget,
    );
  });
}
