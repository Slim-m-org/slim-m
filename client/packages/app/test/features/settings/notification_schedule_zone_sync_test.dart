// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The saved schedule follows the device time zone: re-sent on load and on
/// resume when the two differ, and left alone when they match.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/features/settings/providers/device_timezone.dart';
import 'package:slimm_app/src/features/settings/providers/notification_schedule_zone_sync.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/providers.dart';
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

Map<String, dynamic> _schedule(String zone) => {
  'timezone': zone,
  'days': [
    {'weekday': 0, 'start_minute': 540, 'end_minute': 1020},
  ],
  'off_hours_mode': 'mentions',
  'snooze_until': null,
  'allowed_user_ids': <String>[],
  'allowed_channel_ids': <String>[],
};

void main() {
  testWidgets(
    'a changed device zone re-sends the schedule on load and resume',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var deviceZone = 'America/New_York';
      var storedZone = 'America/New_York';
      final puts = <Map<String, dynamic>>[];
      final events = StreamController<DesktopWindowEventKind>(sync: true);
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          deviceTimezoneProvider.overrideWith((ref) async => deviceZone),
          appLifecycleProvider.overrideWith(
            (ref) => AppLifecycleNotifier(
              mobile: false,
              windowEvents: events.stream,
            ),
          ),
          mockApiOverride((request) async {
            if (request.method == 'PUT') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              puts.add(body);
              storedZone = body['timezone'] as String;
            }
            return _json({'schedule': _schedule(storedZone)});
          }),
        ],
      );
      addTearDown(container.dispose);

      container.listen(notificationScheduleZoneSyncProvider, (_, _) {});
      await tester.pump(const Duration(milliseconds: 50));
      expect(puts, isEmpty, reason: 'same zone, nothing to send');

      deviceZone = 'Europe/Paris';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(puts, hasLength(1));
      expect(puts.single['timezone'], 'Europe/Paris');
      expect(puts.single['off_hours_mode'], 'mentions');
    },
  );
}
