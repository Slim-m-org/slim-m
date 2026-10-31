// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The persistent composer banner that names an active timeout: when it
/// lifts, and why, if the moderator left a reason. See MOD6.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/format.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/screens/channel_composer_area.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// An api whose only route ever hit here is the one the composer's own
/// suggestion sources fall back on when unanswered: nothing this suite cares
/// about depends on any of them resolving.
api.SlimmApi _idleApi(Ref ref) => testApi(
  (_) async => http.Response('{}', 404),
  session: ref.watch(sessionProvider),
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
  testWidgets(
    'shows the timeout banner naming the expiry and reason when timed out',
    (tester) async {
      final until = DateTime.now()
          .add(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      await tester.pumpWidget(
        _harness(
          me: _me(timedOutUntil: until, timeoutReason: 'spamming links'),
        ),
      );
      await tester.pump();
      await tester.pump();

      final when = formatDateTime(until, use24Hour: true);
      expect(find.text('You are timed out until $when.'), findsOneWidget);
      expect(find.text('Reason: spamming links'), findsOneWidget);
    },
  );

  testWidgets('omits the reason line when the moderator left none', (
    tester,
  ) async {
    final until = DateTime.now()
        .add(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    await tester.pumpWidget(_harness(me: _me(timedOutUntil: until)));
    await tester.pump();
    await tester.pump();

    final when = formatDateTime(until, use24Hour: true);
    expect(find.text('You are timed out until $when.'), findsOneWidget);
    expect(find.textContaining('Reason:'), findsNothing);
  });

  testWidgets('shows no timeout banner when the caller is not timed out', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(me: _me()));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('You are timed out'), findsNothing);
    expect(find.textContaining('Reason:'), findsNothing);
  });

  testWidgets('shows no timeout banner once the timeout has already elapsed', (
    tester,
  ) async {
    final past = DateTime.now()
        .subtract(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    await tester.pumpWidget(
      _harness(
        me: _me(timedOutUntil: past, timeoutReason: 'old reason'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('You are timed out'), findsNothing);
  });
}
