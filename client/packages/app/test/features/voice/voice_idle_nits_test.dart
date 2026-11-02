// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle lounge's small honesty fixes: the "N more" link starts where the
/// list does, "Open canvas" reads as a button, and the join bar's status line
/// no longer repeats the title.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_moments_view.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_timeline_model.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/voice_join_bar.dart';
import 'package:slimm_design_system/design_system.dart';

const _viewKey = ValueKey('moments');
const _day = 24 * 60 * 60 * 1000;

Widget _app(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(32), child: child),
        ),
      ),
    );

CallMoment _moment(CallMomentKind kind, int at) =>
    CallMoment(at: at, kind: kind);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the moments list', () {
    Future<void> pump(WidgetTester tester, {int canvasObjects = 0}) async {
      await tester.pumpWidget(
        _app(
          CallMomentsView(
            key: _viewKey,
            moments: [
              _moment(CallMomentKind.started, 1),
              _moment(CallMomentKind.joined, 2),
              _moment(CallMomentKind.joined, 3),
              _moment(CallMomentKind.ended, 4),
            ],
            canvasObjectCount: canvasObjects,
            onOpenCanvas: () {},
            collapsedTo: 2,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('the fold link starts at the list edge', (tester) async {
      await pump(tester);

      final link = tester.getTopLeft(find.text('2 more'));
      expect(link.dx, tester.getTopLeft(find.byKey(_viewKey)).dx);
    });

    testWidgets('the fold link opens the rest', (tester) async {
      await pump(tester);

      await tester.tap(find.text('2 more'));
      await tester.pump();
      expect(find.text('2 more'), findsNothing);
      expect(find.text('Call ended'), findsOneWidget);
    });

    testWidgets('Open canvas is a bordered button, not a caption', (
      tester,
    ) async {
      await pump(tester, canvasObjects: 3);
      await tester.tap(find.text('2 more'));
      await tester.pump();

      final button = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Open canvas'),
      );
      expect(button.variant, AppButtonVariant.secondary);
    });
  });

  group('the join bar status line', () {
    const channel = 'c1';
    const ann = api.VoiceRosterParticipant(userId: 'ann', displayName: 'Ann');

    Future<void> pump(
      WidgetTester tester, {
      required List<api.VoiceRosterParticipant> here,
      int? lastCallAt,
    }) async {
      await tester.pumpWidget(
        _app(
          VoiceJoinBar(
            channelId: channel,
            compact: false,
            lastCallAt: lastCallAt,
            now: _day * 3,
            onJoin: () {},
          ),
          overrides: [
            voiceRosterProvider(
              channel,
            ).overrideWith((ref) => Stream.value(here)),
            channelMembersProvider(
              channel,
            ).overrideWith((ref) async => const <api.UserProfile>[]),
            presenceSeedProvider(channel).overrideWith((ref) async {}),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('does not say "empty" beside "Nobody\'s here"', (tester) async {
      await pump(tester, here: const [], lastCallAt: _day * 2);

      expect(find.text("Nobody's here right now"), findsOneWidget);
      expect(find.textContaining('empty'), findsNothing);
      expect(find.textContaining('last call'), findsOneWidget);
    });

    testWidgets('does not count people the title already names', (
      tester,
    ) async {
      await pump(tester, here: const [ann], lastCallAt: _day * 2);

      expect(find.text('Ann is here'), findsOneWidget);
      expect(find.textContaining('in the call'), findsNothing);
    });

    testWidgets('has no status line when there was no earlier call', (
      tester,
    ) async {
      await pump(tester, here: const []);

      expect(find.textContaining('last call'), findsNothing);
    });
  });
}
