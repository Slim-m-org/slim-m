// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channels offer to open a board: a voice channel only while its canvas
/// is on, never a canvas channel (the board is the channel), always a DM.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_open_button.dart';
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_rtc/rtc.dart';

import '../voice/voice_call_controls_harness.dart';

Channel _row(String kind, {bool? canvas, bool? voice}) => Channel(
  id: 'c1',
  name: 'room',
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  canvasEnabled: canvas,
  voiceEnabled: voice,
);

Override _channel(Channel? row) =>
    channelByIdProvider('c1').overrideWith((ref) => Stream.value(row));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Channel? row, {
  required bool isVoice,
  bool isDm = false,
}) async {
  final container = ProviderContainer(overrides: [_channel(row)]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(key: Key('before'), width: 40, height: 40),
              CanvasOpenButton(channelId: 'c1', isVoice: isVoice, isDm: isDm),
              const SizedBox(key: Key('after'), width: 40, height: 40),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  final rows = <String, (Channel?, bool, bool, bool)>{
    'voice, canvas on': (
      _row('voice', canvas: true, voice: true),
      true,
      false,
      true,
    ),
    'voice, canvas off': (
      _row('voice', canvas: false, voice: true),
      true,
      false,
      false,
    ),
    'voice, flag absent': (_row('voice'), true, false, true),
    'voice, row not loaded': (null, true, false, true),
    'canvas channel': (
      _row('canvas', canvas: true, voice: true),
      false,
      false,
      false,
    ),
    'dm': (_row('dm'), false, true, true),
    'text': (_row('text'), false, false, false),
  };
  for (final MapEntry(:key, :value) in rows.entries) {
    final (row, isVoice, isDm, shown) = value;
    testWidgets('shows table: $key', (tester) async {
      await _pump(tester, row, isVoice: isVoice, isDm: isDm);
      expect(
        find.bySemanticsLabel('Open canvas'),
        shown ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('a hidden button leaves no gap between its neighbours', (
    tester,
  ) async {
    await _pump(
      tester,
      _row('voice', canvas: false, voice: true),
      isVoice: true,
    );
    final before = tester.getTopRight(find.byKey(const Key('before')));
    final after = tester.getTopLeft(find.byKey(const Key('after')));
    expect(after.dx, before.dx);
  });

  testWidgets('the call dock offers no canvas toggle while the canvas is off', (
    tester,
  ) async {
    await pumpVoiceCallDock(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
      canvasChannelId: 'c1',
      extraOverrides: [_channel(_row('voice', canvas: false, voice: true))],
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Open canvas'), findsNothing);
  });

  testWidgets(
    'the call dock keeps its canvas entry in More while the canvas is on',
    (tester) async {
      await pumpVoiceCallDock(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
        canvasChannelId: 'c1',
        extraOverrides: [_channel(_row('voice', canvas: true, voice: true))],
      );
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Open canvas'), findsOneWidget);
    },
  );
}
