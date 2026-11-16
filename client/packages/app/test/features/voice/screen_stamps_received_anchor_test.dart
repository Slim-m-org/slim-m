// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Pictures on your screen" from the call dock's share menu (decision 0121)
/// opens above the dock, as the share menu itself does, so it covers no control.
library;

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_stamps_received_sheet.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _sharing = VoiceFlags(
  state: VoiceSessionState.connected,
  screenSharing: true,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('it opens above the dock, from the share control', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpVoiceCallDock(
      tester,
      _sharing,
      width: 1280,
      session: InertSession(needsSource: true),
      extraOverrides: [
        canvasStampsSupportedProvider.overrideWithValue(true),
        receivedScreenStampsProvider.overrideWith(
          (ref) async => [
            api.ReceivedScreenStamp(
              id: 's1',
              channelId: 'call',
              senderId: 'u1',
              attachmentId: 'a1',
              createdAt: DateTime.now().millisecondsSinceEpoch,
              reported: false,
            ),
          ],
        ),
      ],
    );
    final share = tester.getRect(find.byTooltip('Screen share options'));

    await tester.tap(find.byTooltip('Screen share options'));
    await _settle(tester);
    await tester.tap(find.text('Pictures on your screen'));
    await _settle(tester);
    await _settle(tester);

    final title = tester.getRect(find.text('Pictures on your screen'));
    final lowest = tester.getRect(find.text('Block'));
    expect(lowest.bottom, lessThan(share.top), reason: 'clear of the dock');
    expect(title.left, lessThan(share.right), reason: 'over the share control');
  });
}
