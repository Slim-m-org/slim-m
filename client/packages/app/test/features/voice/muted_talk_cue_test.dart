// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Talking while muted raises one quiet cue on the mic, never while unmuted.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/call_dock_hint.dart';
import 'package:slimm_app/src/features/voice/providers/muted_talk_cue.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_hint.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _muted = VoiceFlags(
  state: VoiceSessionState.connected,
  microphoneEnabled: false,
);
const _live = VoiceFlags(state: VoiceSessionState.connected);

const _speech = InputGateReading(levelDb: -30, voice: true);
const _silence = InputGateReading(levelDb: -90, voice: false);

Future<InertSession> _pump(
  WidgetTester tester,
  VoiceFlags flags, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    shareHintSeenKey: true,
    micCueSeenKey: '',
    ...prefs,
  });
  final session = InertSession(supportsInputGate: true);
  addTearDown(session.gateReadings.close);
  await pumpVoiceCallDock(tester, flags, session: session);
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return session;
}

Future<void> _talk(WidgetTester tester, InertSession session, int ms) async {
  for (var t = 0; t < ms; t += 50) {
    session.gateReadings.add(_speech);
    await tester.pump(const Duration(milliseconds: 50));
  }
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('shows after a second of speech while muted', (tester) async {
    final session = await _pump(tester, _muted);
    await _talk(tester, session, 500);
    expect(find.byKey(DockHintAnchor.bubbleKey), findsNothing);
    await _talk(tester, session, 700);
    expect(find.bySemanticsLabel(mutedTalkCueText), findsOneWidget);
  });

  testWidgets('a pause resets the count', (tester) async {
    final session = await _pump(tester, _muted);
    await _talk(tester, session, 700);
    session.gateReadings.add(_silence);
    await tester.pump(const Duration(milliseconds: 50));
    await _talk(tester, session, 700);
    expect(find.byKey(DockHintAnchor.bubbleKey), findsNothing);
  });

  testWidgets('stays quiet while unmuted', (tester) async {
    final session = await _pump(tester, _live);
    await _talk(tester, session, 2000);
    expect(find.byKey(DockHintAnchor.bubbleKey), findsNothing);
  });

  testWidgets('stays quiet on push to talk', (tester) async {
    final session = await _pump(
      tester,
      _muted,
      prefs: {'slimm.voice.push_to_talk_enabled': true},
    );
    await _talk(tester, session, 2000);
    expect(find.byKey(DockHintAnchor.bubbleKey), findsNothing);
  });

  testWidgets('does not come back for the same mute', (tester) async {
    final session = await _pump(tester, _muted);
    await _talk(tester, session, 1200);
    expect(find.bySemanticsLabel(mutedTalkCueText), findsOneWidget);
    await tester.pump(dockHintDuration + const Duration(seconds: 1));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.byKey(DockHintAnchor.bubbleKey), findsNothing);
    await _talk(tester, session, 3000);
    expect(find.byKey(DockHintAnchor.bubbleKey), findsNothing);
  });

  testWidgets('is absent where the host has no input gate', (tester) async {
    SharedPreferences.setMockInitialValues({
      shareHintSeenKey: true,
      micCueSeenKey: '',
    });
    final session = InertSession();
    addTearDown(session.gateReadings.close);
    await pumpVoiceCallDock(tester, _muted, session: session);
    await _talk(tester, session, 2000);
    expect(find.byKey(DockHintAnchor.bubbleKey), findsNothing);
  });
}
