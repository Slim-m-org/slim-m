// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share options menu offers a share's audio switch only while one is running with audio.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
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

AppToggle _audioSwitch(WidgetTester tester) => tester.widget<AppToggle>(
  find.descendant(
    of: find.widgetWithText(AppMenuItem, 'Share audio'),
    matching: find.bySubtype<AppToggle>(),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a share with audio on offers to mute it', (tester) async {
    await pumpControls(tester, _sharing(ShareAudio.on));
    await _openMenu(tester);

    expect(find.text('Share audio'), findsOneWidget);
    expect(_audioSwitch(tester).value, isTrue);
  });

  testWidgets('a muted share offers to unmute it', (tester) async {
    await pumpControls(tester, _sharing(ShareAudio.muted));
    await _openMenu(tester);

    expect(find.text('Share audio'), findsOneWidget);
    expect(_audioSwitch(tester).value, isFalse);
  });

  testWidgets('a share with no audio offers no switch', (tester) async {
    await pumpControls(tester, _sharing(ShareAudio.none));
    await _openMenu(tester);

    expect(find.text('Share audio'), findsNothing);
  });

  testWidgets('no share, no switch', (tester) async {
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
    );
    await _openMenu(tester);

    expect(find.text('Share audio'), findsNothing);
  });
}
