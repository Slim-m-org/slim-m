// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share options menu offers a share's audio switch only while one is running with audio.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _caretLabel = 'Screen share options';

VoiceFlags _sharing(ShareAudio audio) => VoiceFlags(
  state: VoiceSessionState.connected,
  screenSharing: true,
  shareAudio: audio,
);

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip(_caretLabel));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a share with audio on offers to mute it', (tester) async {
    await pumpControls(tester, _sharing(ShareAudio.on));
    await _openMenu(tester);

    expect(find.text('Mute shared audio'), findsOneWidget);
    expect(find.text('Unmute shared audio'), findsNothing);
  });

  testWidgets('a muted share offers to unmute it', (tester) async {
    await pumpControls(tester, _sharing(ShareAudio.muted));
    await _openMenu(tester);

    expect(find.text('Unmute shared audio'), findsOneWidget);
  });

  testWidgets('a share with no audio offers no switch', (tester) async {
    await pumpControls(tester, _sharing(ShareAudio.none));
    await _openMenu(tester);

    expect(find.textContaining('shared audio'), findsNothing);
  });

  testWidgets('no share, no switch', (tester) async {
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
    );
    await _openMenu(tester);

    expect(find.textContaining('shared audio'), findsNothing);
  });
}
