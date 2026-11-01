// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call with no bot on it has no watch session, and asking anyway logged a
/// 404 in the browser console on every join.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/widgets/watch_session_bar.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

api.UserProfile _member(String id, {bool bot = false}) => api.UserProfile(
  id: id,
  username: id,
  displayName: id,
  createdAt: 0,
  isBot: bot,
);

Future<List<Uri>> _pump(WidgetTester tester, List<String> participants) async {
  final requests = <Uri>[];
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      membersProvider.overrideWith(
        (ref) async => [_member('ada'), _member('jelly', bot: true)],
      ),
      apiProvider.overrideWith((ref) {
        final client = testApi(
          (request) async {
            requests.add(request.url);
            return http.Response('{}', 404);
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
        home: Scaffold(
          body: WatchSessionGate(
            channelId: 'call-1',
            participantIds: participants,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return requests;
}

void main() {
  testWidgets('people only: the watch session is never requested', (
    tester,
  ) async {
    final requests = await _pump(tester, ['ada']);

    expect(requests.where((u) => u.path.contains('watch-session')), isEmpty);
  });

  testWidgets('a bot on the call: the session is read', (tester) async {
    final requests = await _pump(tester, ['ada', 'jelly']);

    expect(
      requests.where((u) => u.path == '/channels/call-1/watch-session'),
      hasLength(1),
    );
  });
}
