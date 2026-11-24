// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The own-account frame for notification state, and the snooze body that
/// names a duration rather than a device-clock deadline.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses account_notifications.changed', () {
    final event = ServerEvent.parse(
      jsonEncode(
          {'type': 'account_notifications.changed', 'scope': 'schedule'}),
    );
    expect(event, isA<AccountNotificationsChanged>());
    expect((event as AccountNotificationsChanged).scope, 'schedule');
  });

  test('a snooze sends seconds, never a device-clock deadline', () async {
    Map<String, dynamic>? body;
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'snooze_until': 123}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final until = await api.setNotificationSnooze(const Duration(minutes: 30));

    expect(until, 123);
    expect(body?['duration_seconds'], 1800);
    expect(body?['until_ms'], isA<int>(),
        reason: 'older servers read this one');
  });
}
