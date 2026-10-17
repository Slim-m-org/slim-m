// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The recap screen's own way out: [VoiceRejoinScreen] used to end at
/// "Rejoin call" (or nothing, for a failure that cannot retry), leaving no
/// way back to the channel the call belonged to. This covers
/// [leaveRecapScreen], tapped rather than called directly, so the route it
/// leaves the screen at is exactly what a real navigation would produce.
///
/// A real voice channel has no separate text view of its own to route back
/// to - `ConversationPane` shows this same screen for as long as the
/// channel's kind says voice - so leaving means leaving the channel
/// entirely, at `Routes.channels`. A DM's call is only ever a mode of that
/// channel's own pane, so leaving it closes back to messages without
/// touching the route at all; see `voice_join_preview.dart`'s own doc for
/// both destinations.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/voice/screens/voice_join_preview.dart';
import 'package:slimm_design_system/design_system.dart';

void _noop() {}

class _Harness {
  _Harness(this.router, this.container);

  final GoRouter router;
  final ProviderContainer container;

  String get location =>
      router.routerDelegate.currentConfiguration.uri.toString();
}

Future<_Harness> _pump(
  WidgetTester tester,
  Widget rejoinScreen, {
  required String initialLocation,
}) async {
  final container = ProviderContainer(
    overrides: [
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) => Scaffold(body: rejoinScreen),
      ),
      GoRoute(
        path: Routes.channels,
        builder: (context, state) => const Scaffold(body: Text('channel list')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();

  return _Harness(router, container);
}

void main() {
  testWidgets(
    'a real voice channel leaves for the channel list, not a dead end',
    (tester) async {
      final harness = await _pump(
        tester,
        const VoiceRejoinScreen(
          channelId: 'channel-1',
          isDm: false,
          canRetry: true,
          onRetry: _noop,
        ),
        initialLocation: '/channels/channel-1',
      );

      await tester.tap(find.text('Back to channel'));
      await tester.pumpAndSettle();

      expect(harness.location, Routes.channels);
    },
  );

  testWidgets(
    'an unretryable failure still leaves a way out, not just a dead end',
    (tester) async {
      final harness = await _pump(
        tester,
        const VoiceRejoinScreen(
          channelId: 'channel-1',
          isDm: false,
          canRetry: false,
          onRetry: _noop,
          errorMessage: 'This voice channel no longer exists.',
        ),
        initialLocation: '/channels/channel-1',
      );

      // The retry it cannot act on is gone; the way out is what remains.
      expect(find.text('Rejoin call'), findsNothing);
      expect(find.text('Try again'), findsNothing);

      await tester.tap(find.text('Back to channel'));
      await tester.pumpAndSettle();

      expect(harness.location, Routes.channels);
    },
  );

  testWidgets('a DM call closes back to messages instead of routing away', (
    tester,
  ) async {
    final harness = await _pump(
      tester,
      const VoiceRejoinScreen(
        channelId: 'dm-1',
        isDm: true,
        canRetry: true,
        onRetry: _noop,
      ),
      initialLocation: '/channels/dm-1',
    );
    harness.container.read(dmCallOpenProvider.notifier).state = 'dm-1';

    await tester.tap(find.text('Back to messages'));
    await tester.pumpAndSettle();

    expect(harness.container.read(dmCallOpenProvider), isNull);
    // No route change: a DM call is a mode of its own pane, not a route.
    expect(harness.location, '/channels/dm-1');
  });
}
