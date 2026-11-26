// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas dock with a call: drawing tools on the left, the call group on the
/// right with clear space between, and only the primary call controls plus More.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/live_call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/canvas_call_dock_fixtures.dart';

const _voice = VoiceFlags(state: VoiceSessionState.connected, channelId: 'c1');

Future<void> _pump(
  WidgetTester tester,
  double window, {
  bool toolsHidden = false,
}) async {
  tester.view.physicalSize = Size(window, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final compact = window < 600;
  await pumpCanvasCallDock(
    tester,
    withCall: true,
    callVoice: _voice,
    canvas: buildCanvasDockData(canUndo: true, toolsHidden: toolsHidden),
    width: compact ? window - 24 : window,
    touch: compact,
    compact: compact,
    overrides: [
      canvasStampsSupportedProvider.overrideWithValue(false),
      myChannelPermissionsProvider('c1').overrideWithValue(
        Perm.connect |
            Perm.speak |
            Perm.useSoundboard |
            Perm.viewChannel |
            Perm.viewTranscripts,
      ),
      liveCallTranscriptIdProvider('c1').overrideWithValue('t1'),
    ],
  );
  await tester.pump();
}

Rect _label(WidgetTester tester, String label) =>
    tester.getRect(find.bySemanticsLabel(RegExp('^$label\$')).first);

void main() {
  for (final window in [1280.0, 1024.0, 800.0]) {
    testWidgets('at $window the tools sit left and the call group right with '
        'clear space between', (tester) async {
      await _pump(tester, window);
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.bySubtype<FloatingDockCard>());
      final redo = _label(tester, 'Redo');
      final overflow = _label(tester, 'More canvas actions');
      final mute = _label(tester, 'Mute');
      final leave = _label(tester, 'Leave call');
      final toolsEnd = overflow.right > redo.right
          ? overflow.right
          : redo.right;
      expect(mute.left - toolsEnd, greaterThanOrEqualTo(24));
      expect(leave.right, lessThanOrEqualTo(card.right));
      expect(card.right, lessThanOrEqualTo(window));
      expect(card.left, greaterThanOrEqualTo(0));
      final more = _label(tester, 'More');
      expect(more.left, greaterThan(_label(tester, 'Share a screen').right));
      expect(more.right, lessThanOrEqualTo(leave.left));
      for (final label in ['Soundboard', 'Captions', 'Mark this moment']) {
        expect(find.bySemanticsLabel(RegExp('^$label')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('narrow, tools and call share one card, the tools row above the '
      'call row', (tester) async {
    await _pump(tester, 640);
    expect(tester.takeException(), isNull);
    expect(find.bySubtype<FloatingDockCard>(), findsOneWidget);
    expect(
      _label(tester, 'Pen').bottom,
      lessThanOrEqualTo(_label(tester, 'Mute').top),
    );
    final card = tester.getRect(find.bySubtype<FloatingDockCard>());
    for (final e in find.bySubtype<CallDockButton>().evaluate()) {
      final r = tester.getRect(find.byElementPredicate((x) => x == e));
      expect(r.right, lessThanOrEqualTo(card.right));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
    'folding the tools away leaves the call group alone in the card',
    (tester) async {
      await _pump(tester, 640, toolsHidden: true);
      expect(find.bySemanticsLabel(RegExp('^Pen')), findsNothing);
      expect(_label(tester, 'More').right, lessThanOrEqualTo(640));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets('at phone width nothing in the call card clips', (tester) async {
    await _pump(tester, 390);
    expect(tester.takeException(), isNull);
    for (final e in find.bySubtype<CallDockButton>().evaluate()) {
      final r = tester.getRect(find.byElementPredicate((x) => x == e));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(390));
    }
    expect(_label(tester, 'More').bottom, lessThanOrEqualTo(900));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
