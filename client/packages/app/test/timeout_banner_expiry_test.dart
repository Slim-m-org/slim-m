// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/channel_composer_area.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// An api whose only route ever hit here is the one the composer's own
/// suggestion sources fall back on when unanswered: nothing this suite cares
/// about depends on any of them resolving.
api.SlimmApi _idleApi(Ref ref) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: ref.watch(sessionProvider),
  httpClient: MockClient((_) async => http.Response('{}', 404)),
);

api.Me _me({int? timedOutUntil, String? timeoutReason}) => api.Me(
  id: 'self',
  username: 'nia',
  displayName: 'Nia',
  createdAt: 0,
  permissions: 0,
  timedOutUntil: timedOutUntil,
  timeoutReason: timeoutReason,
);

Widget _harness({required api.Me me}) => ProviderScope(
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    apiProvider.overrideWith(_idleApi),
    meProvider.overrideWith((ref) async => me),
    // Fixed, so the rendered timestamp does not depend on the host locale.
    timeFormatControllerProvider.overrideWith(
      (ref) => TimeFormatController(ref)..state = TimeFormatPreference.h24,
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: ChannelComposerArea(
        channelId: 'c1',
        controller: TextEditingController(),
        channelName: 'general',
        onSend: (_) async {},
        replyingTo: null,
        onCancelReply: () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('the banner goes away by itself once the timeout expires', (
    tester,
  ) async {
    final until = DateTime.now()
        .add(const Duration(milliseconds: 600))
        .millisecondsSinceEpoch;
    await tester.pumpWidget(_harness(me: _me(timedOutUntil: until)));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('You are timed out'), findsOneWidget);

    // Wall clock moves past the expiry; the widget tree is pumped as a user session would be.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 900)),
    );
    expect(DateTime.now().millisecondsSinceEpoch, greaterThan(until));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(
      find.textContaining('You are timed out'),
      findsNothing,
      reason:
          'timeout expired ${DateTime.now().millisecondsSinceEpoch - until}ms ago',
    );
  });
}
