// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In More, an on_request call with nothing running gets a plain toggle row
/// instead of a submenu holding one switch; more than the switch keeps the submenu.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/call_captions.dart';
import 'package:slimm_app/src/features/voice/providers/live_call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _voice = VoiceFlags(state: VoiceSessionState.connected, channelId: 'c1');

Future<void> _openMore(WidgetTester tester, CaptionsControl control) async {
  await pumpVoiceCallDock(
    tester,
    _voice,
    extraOverrides: [
      myChannelPermissionsProvider(
        'c1',
      ).overrideWithValue(Perm.connect | Perm.speak | Perm.viewChannel),
      captionsControlProvider('c1').overrideWithValue(control),
      liveCallTranscriptIdProvider(
        'c1',
      ).overrideWithValue(control == CaptionsControl.running ? 't1' : null),
    ],
  );
  await tester.pump();
  await tester.tap(
    find.byWidgetPredicate(
      (w) => w is CallDockButton && w.tooltip.startsWith('More'),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _captionsSubmenu() => find.descendant(
  of: find.bySubtype<AppSubmenuItem>(),
  matching: find.text('Captions'),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('idle on_request is a toggle row, not a submenu', (tester) async {
    await _openMore(tester, CaptionsControl.startable);
    expect(find.text('Show captions'), findsOneWidget);
    expect(_captionsSubmenu(), findsNothing);
    expect(find.bySubtype<AppMenuSwitchRow>(), findsOneWidget);
    expect(find.text('Captions'), findsNothing, reason: 'no parent row');
  });

  testWidgets('the toggle row starts the ask through the sheet', (
    tester,
  ) async {
    await _openMore(tester, CaptionsControl.startable);
    await tester.tap(find.text('Show captions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Transcribe this call?'), findsOneWidget);
  });

  testWidgets(
    'a running transcript keeps the submenu with a Show captions switch',
    (tester) async {
      await _openMore(tester, CaptionsControl.running);
      expect(find.text('Captions'), findsOneWidget);
      expect(_captionsSubmenu(), findsOneWidget);
      await tester.tap(find.text('Captions'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Show captions'), findsOneWidget);
      expect(find.text('Mark this moment'), findsOneWidget);
    },
  );
}
