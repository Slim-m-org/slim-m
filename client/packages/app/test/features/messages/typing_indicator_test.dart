// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `TypingIndicator`: it renders every remote typist, but never
/// the caller's own id, since the server fans a typist's own frame back to
/// their own connections too (for a second device to show it).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/typing_indicator.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets(
    'a typing frame carrying the caller\'s own id never renders, even alone '
    'in the channel - the shape a personal space is in',
    (tester) async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);

      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(events.stream),
          membersProvider.overrideWith((ref) async => <api.UserProfile>[]),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: TypingIndicator(channelId: 'c1')),
          ),
        ),
      );

      events.add(const api.TypingStarted(channelId: 'c1', userId: 'self'));
      await tester.pumpAndSettle();

      expect(find.textContaining('is typing'), findsNothing);
      expect(find.textContaining('are typing'), findsNothing);
    },
  );

  testWidgets('someone else typing still renders', (tester) async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);

    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        membersProvider.overrideWith(
          (ref) async => const [
            api.UserProfile(
              id: 'other',
              username: 'priya',
              displayName: 'Priya',
              createdAt: 0,
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: TypingIndicator(channelId: 'c1')),
        ),
      ),
    );

    events.add(const api.TypingStarted(channelId: 'c1', userId: 'other'));
    // Bounded pumps, never pumpAndSettle: the dots deliberately loop.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Priya is typing…'), findsOneWidget);
    expect(find.byType(AppTypingDots), findsOneWidget);
  });
}
