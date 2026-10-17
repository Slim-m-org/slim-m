// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for how a call recap reaches the screen: [recapForChannel]'s
/// channel guard (`voice_screen.dart` is one `VoiceController` for every
/// channel, so a stale recap from elsewhere must never leak in) and
/// [VoiceRejoinScreen]'s rendering choice between the recap, a plain error,
/// and the old bare "You left this call." line.
///
/// Split from `voice_screen_test.dart`, which already sits at this repo's
/// file budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/call_recap.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_join_preview.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_recap_card.dart';
import 'package:slimm_design_system/design_system.dart';

/// A recap for [channelId]; [withAlice] false stands in for a call spent
/// entirely alone, which is still worth showing on its own duration.
CallRecap _recap({
  required String channelId,
  Duration duration = const Duration(minutes: 6),
  bool withAlice = true,
}) {
  final start = DateTime(2026, 1, 1);
  return CallRecap(
    channelId: channelId,
    startedAt: start,
    endedAt: start.add(duration),
    others: withAlice
        ? [
            CallParticipantActivity(
              identity: 'user-2',
              name: 'Alice',
              joinedAt: start,
            ),
          ]
        : const [],
    sharedScreen: false,
    usedCamera: false,
  );
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [
    voiceRosterProvider.overrideWith(
      (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: child),
  ),
);

/// Unlike [_wrap], the roster resolves to a genuinely checked, empty room
/// rather than staying unknown - the combination this file's merge test
/// needs.
Widget _wrapWithEmptyRoster(Widget child) => ProviderScope(
  overrides: [
    voiceRosterProvider.overrideWith(
      (ref, channelId) => Stream.value(const <VoiceRosterParticipant>[]),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: child),
  ),
);

void main() {
  group('recapForChannel', () {
    test("returns the recap when it belongs to this screen's channel", () {
      final recap = _recap(channelId: 'channel-1');
      final voice = VoiceFlags(recap: recap);

      expect(recapForChannel(voice, 'channel-1'), same(recap));
    });

    test('returns null for a recap left over from a different channel', () {
      final recap = _recap(channelId: 'channel-a');
      final voice = VoiceFlags(recap: recap);

      expect(
        recapForChannel(voice, 'channel-b'),
        isNull,
        reason:
            "VoiceController is one instance for every channel; a recap "
            'from elsewhere must never leak into this screen',
      );
    });

    test('returns null when there is no recap at all', () {
      expect(recapForChannel(const VoiceFlags(), 'channel-1'), isNull);
    });
  });

  group('VoiceRejoinScreen', () {
    /// voice.md: nothing distinguished "this describes the call that just
    /// ended" from "this is who is currently in the call," directly under
    /// the present-tense "Nobody is in this call yet." sentence.
    testWidgets('shows the recap for a real, worthwhile call', (tester) async {
      final recap = _recap(channelId: 'channel-1');

      await tester.pumpWidget(
        _wrap(
          VoiceRejoinScreen(
            channelId: 'channel-1',
            isDm: false,
            canRetry: true,
            onRetry: () {},
            recap: recap,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CallRecapCard), findsOneWidget);
      expect(find.text('6 min'), findsOneWidget);
      expect(find.text('You left this call.'), findsNothing);
      expect(find.text('Your last call'), findsOneWidget);
    });

    testWidgets('falls back to the plain notice for a call not worth showing', (
      tester,
    ) async {
      final recap = _recap(
        channelId: 'channel-1',
        duration: const Duration(minutes: 4, seconds: 59),
      );

      await tester.pumpWidget(
        _wrap(
          VoiceRejoinScreen(
            channelId: 'channel-1',
            isDm: false,
            canRetry: true,
            onRetry: () {},
            recap: recap,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(CallRecapCard),
        findsNothing,
        reason: 'a call under five minutes is not a summary, not a summary',
      );
      expect(find.text('You left this call.'), findsOneWidget);
    });

    testWidgets('shows the recap for a real call spent entirely alone', (
      tester,
    ) async {
      final recap = _recap(channelId: 'channel-1', withAlice: false);

      await tester.pumpWidget(
        _wrap(
          VoiceRejoinScreen(
            channelId: 'channel-1',
            isDm: false,
            canRetry: true,
            onRetry: () {},
            recap: recap,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(CallRecapCard),
        findsOneWidget,
        reason:
            'testing a call, screen share or camera alone is still a real '
            'use worth reporting on',
      );
      expect(find.text('6 min'), findsOneWidget);
      expect(find.text('Nobody else joined.'), findsOneWidget);
      expect(find.textContaining('other person'), findsNothing);
    });

    testWidgets('an error takes priority over a recap', (tester) async {
      final recap = _recap(channelId: 'channel-1');

      await tester.pumpWidget(
        _wrap(
          VoiceRejoinScreen(
            channelId: 'channel-1',
            isDm: false,
            canRetry: true,
            onRetry: () {},
            errorMessage: 'Could not reconnect.',
            recap: recap,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CallRecapCard), findsNothing);
      expect(find.text('Could not reconnect.'), findsOneWidget);
    });

    testWidgets('no recap at all shows the plain notice, as before', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          VoiceRejoinScreen(
            channelId: 'channel-1',
            isDm: false,
            canRetry: true,
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CallRecapCard), findsNothing);
      expect(find.text('You left this call.'), findsOneWidget);
    });

    testWidgets(
      'merges the empty room and left-call facts into one sentence for a '
      'short or solo call with a confirmed-empty roster',
      (tester) async {
        final recap = _recap(
          channelId: 'channel-1',
          duration: const Duration(seconds: 4),
        );

        await tester.pumpWidget(
          _wrapWithEmptyRoster(
            VoiceRejoinScreen(
              channelId: 'channel-1',
              isDm: false,
              canRetry: true,
              onRetry: () {},
              recap: recap,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You left this call. Nobody else is here.'),
          findsOneWidget,
        );
        expect(
          find.text('Nobody is in this call yet.'),
          findsNothing,
          reason: 'the two facts must read as one sentence, not two',
        );
        expect(find.text('You left this call.'), findsNothing);
      },
    );
  });
}
