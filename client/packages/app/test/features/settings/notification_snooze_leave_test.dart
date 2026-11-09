// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving the pane while a snooze is being saved must neither throw nor
/// leave the cached schedule stale for the message alert policy.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/features/settings/widgets/notification_snooze_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('a snooze saved after the pane closed still lands in the cache', (
    tester,
  ) async {
    final saved = Completer<void>();
    var snoozeUntil = 0;
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'self',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        mockApiOverride((request) async {
          if (request.url.path == '/notifications/schedule/snooze') {
            await saved.future;
            snoozeUntil =
                (jsonDecode(request.body) as Map<String, dynamic>)['until_ms']
                    as int;
            return _json({'snooze_until': snoozeUntil});
          }
          if (request.url.path == '/notifications/schedule') {
            reads++;
            return _json({
              'schedule': {
                'timezone': 'America/New_York',
                'days': [
                  {'weekday': 0, 'start_minute': 540, 'end_minute': 1020},
                ],
                'off_hours_mode': 'mentions',
                'snooze_until': snoozeUntil == 0 ? null : snoozeUntil,
                'allowed_user_ids': <String>[],
                'allowed_channel_ids': <String>[],
              },
            });
          }
          return http.Response('', 404);
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(notificationScheduleProvider, (_, _) {});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: NotificationSnoozeSection()),
        ),
      ),
    );
    await waitUntil(
      tester,
      () => container.read(notificationScheduleProvider).hasValue,
    );

    await tester.tap(find.text('30m'));
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    saved.complete();
    await pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(reads, 2);
    expect(container.read(notificationScheduleProvider).value?.isSnoozed, true);
  });
}
