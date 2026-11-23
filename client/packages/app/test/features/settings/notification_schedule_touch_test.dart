// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone the schedule's day chips keep a full touch target each, in a row
/// of their own, instead of being scaled down with the row.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/device_timezone.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/notification_schedule_section.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

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
      mockApiOverride((request) async {
        if (request.url.path == '/members') return _json(<dynamic>[]);
        return handler(request);
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
            child: Column(children: [NotificationScheduleSection()]),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every day chip is at least 44dp square at 390 wide', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      (request) async => _json({'schedule': _scheduleJson()}),
    );

    final chips = find.ancestor(
      of: find.text('S'),
      matching: find.byType(FocusableTapTarget),
    );
    expect(chips, findsNWidgets(2));
    for (final chip in chips.evaluate()) {
      final size = tester.getRect(find.byWidget(chip.widget)).size;
      expect(size.width, greaterThanOrEqualTo(43.5));
      expect(size.height, greaterThanOrEqualTo(43.5));
    }
    final first = tester.getTopLeft(chips.first).dy;
    final last = tester.getTopLeft(chips.last).dy;
    expect(first, closeTo(last, 0.5), reason: 'one row of chips');
    expect(tester.takeException(), isNull);
  });
}
