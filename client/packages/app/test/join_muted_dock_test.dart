// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock says why the mic does nothing: the channel joined it muted,
/// or the member cannot speak here at all (no SPEAK, or timed out).
///
/// Width decides the layout, not platform (desktop-vs-mobile.md, rule 1), so
/// every case runs at 1280 and at 390 with touch density.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/voice_state.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

VoiceFlags _call({
  bool canPublish = true,
  bool joinedMuted = false,
  bool mic = false,
}) => VoiceFlags(
  state: VoiceSessionState.connected,
  microphoneEnabled: mic,
  canPublish: canPublish,
  joinedMuted: joinedMuted,
);

api.Me _me({int? timedOutUntil}) => api.Me(
  id: 'self',
  username: 'nia',
  displayName: 'Nia',
  createdAt: 0,
  permissions: 0,
  timedOutUntil: timedOutUntil,
);

Finder _tip(String prefix) => find.byWidgetPredicate(
  (w) => w is Tooltip && (w.message ?? '').startsWith(prefix),
);

BoxDecoration _chip(WidgetTester tester, IconData icon) =>
    tester
            .widget<Container>(
              find
                  .ancestor(
                    of: find.byIcon(icon),
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .decoration!
        as BoxDecoration;

Future<void> _pump(
  WidgetTester tester,
  VoiceFlags voice,
  double width, {
  api.Me? me,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpVoiceCallDock(
    tester,
    voice,
    width: width,
    touch: width < 600,
    extraOverrides: [
      if (me != null) meProvider.overrideWith((ref) async => me),
    ],
  );
  await tester.pump();
}

void main() {
  const tokens = AppTokens.light;

  test(
    'touching the mic clears the joined-muted note, other changes keep it',
    () {
      const joined = VoiceState(joinedMuted: true);
      expect(joined.copyWith(cameraEnabled: true).joinedMuted, isTrue);
      expect(joined.copyWith(microphoneEnabled: true).joinedMuted, isFalse);
      expect(joined.copyWith(microphoneEnabled: false).joinedMuted, isFalse);
    },
  );

  for (final width in [1280.0, 390.0]) {
    group('at ${width.toInt()} wide', () {
      testWidgets('a mic that joined muted says so, and still works', (
        tester,
      ) async {
        await _pump(tester, _call(joinedMuted: true), width);
        expect(
          _tip('Unmute to talk. This channel joins muted.'),
          findsOneWidget,
        );
        expect(_chip(tester, AppIcons.micOff).border, isNotNull);
        expect(
          (_chip(tester, AppIcons.micOff).border! as Border).top.color,
          tokens.dangerBorder,
        );
      });

      testWidgets('a mic the member muted gives no join-muted hint', (
        tester,
      ) async {
        await _pump(tester, _call(), width);
        expect(_tip('Unmute'), findsOneWidget);
        expect(_tip('Unmute to talk'), findsNothing);
      });

      testWidgets('with SPEAK the mic and camera are ordinary controls', (
        tester,
      ) async {
        await _pump(tester, _call(mic: true), width);
        expect(_tip("You can't speak in this channel"), findsNothing);
        expect(_tip('Mute'), findsOneWidget);
        expect(_tip('Turn on camera'), findsOneWidget);
      });

      testWidgets('without SPEAK both read as unavailable and say why', (
        tester,
      ) async {
        await _pump(tester, _call(canPublish: false), width, me: _me());
        expect(_tip("You can't speak in this channel"), findsNWidgets(2));
        expect(_tip('Unmute'), findsNothing);
        expect(_tip('Turn on camera'), findsNothing);
        final mic = _chip(tester, AppIcons.micOff);
        expect(mic.color, tokens.surfaceRaised);
        expect((mic.border! as Border).top.color, tokens.borderSubtle);
        expect(
          tester.widget<Icon>(find.byIcon(AppIcons.micOff)).color,
          tokens.textDisabled,
        );
      });

      testWidgets('a stale mic-on preference still reads as unavailable', (
        tester,
      ) async {
        await _pump(
          tester,
          _call(canPublish: false, mic: true),
          width,
          me: _me(),
        );
        expect(find.byIcon(AppIcons.mic), findsNothing);
        expect(find.byIcon(AppIcons.micOff), findsOneWidget);
      });

      testWidgets('timed out is its own reason', (tester) async {
        final until = DateTime.now().millisecondsSinceEpoch + 3600000;
        await _pump(
          tester,
          _call(canPublish: false),
          width,
          me: _me(timedOutUntil: until),
        );
        expect(_tip('You are timed out'), findsNWidgets(2));
      });

      testWidgets('tapping an unavailable mic explains instead of doing '
          'nothing', (tester) async {
        await _pump(tester, _call(canPublish: false), width, me: _me());
        await tester.tap(find.byIcon(AppIcons.micOff));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text("You can't speak in this channel"), findsOneWidget);
        expect(find.byIcon(AppIcons.mic), findsNothing);
      });

      testWidgets('the unavailable state is exposed as disabled', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _pump(tester, _call(canPublish: false), width, me: _me());
        final node = tester.getSemantics(
          find.bySemanticsLabel("You can't speak in this channel").first,
        );
        expect(
          node.getSemanticsData().flagsCollection.isEnabled,
          Tristate.isFalse,
        );
        semantics.dispose();
      });
    });
  }
}
