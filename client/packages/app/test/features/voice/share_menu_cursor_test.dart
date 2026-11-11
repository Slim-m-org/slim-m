// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Show my cursor" is in the call's share menu, where a sharer in a game reaches for it, not only in Settings.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_storage.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_call_controls_harness.dart';

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => shareCursorVisible.value = true);

  testWidgets('the share menu turns the shared cursor off and remembers it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpVoiceCallDock(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, screenSharing: true),
      width: 900,
      scoped: false,
    );
    await tester.tap(find.byTooltip('Screen share options'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Show my cursor'), findsOneWidget);

    await tester.tap(find.text('Show my cursor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(shareCursorVisible.value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(VoiceSettingKeys.shareCursor), isFalse);
  });
}
