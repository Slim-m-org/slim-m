// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Polish for the desktop share surfaces: unnamed sources get a label, and the
/// pop-out's controls sit on a scrim that fades with them.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart' show ResizeEdge;
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_view.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_source_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

void main() {
  test('a source with no name still gets a distinct label', () {
    expect(
      screenSourceLabel(
        const ScreenShareSource(id: 'w', name: ' ', isWindow: true),
      ),
      'Untitled window',
    );
    expect(
      screenSourceLabel(const ScreenShareSource(id: 's', name: '')),
      'Untitled screen',
    );
    expect(
      screenSourceLabel(const ScreenShareSource(id: 's', name: 'Screen 1')),
      'Screen 1',
    );
  });

  testWidgets('the pop-out scrims span the window edges and fade in on hover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fixture = await fixtureContainer(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            const VoiceState(
              channelId: 'c',
              state: VoiceSessionState.connected,
              participants: [
                VoiceParticipant(
                  identity: 'u-ada',
                  name: 'Ada',
                  isSpeaking: false,
                  isMuted: false,
                  isLocal: false,
                  isScreenSharing: true,
                ),
              ],
            ),
            FakeSession(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: PopOutWindowView(
            feed: (identity: 'u-ada', name: 'Ada', kind: FeedKind.screenShare),
            frame: PopOutFrame(
              onMoveStart: () {},
              onResizeStart: (ResizeEdge _) {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    double opacity(Key k) =>
        tester.widget<AnimatedOpacity>(find.byKey(k)).opacity;
    expect(opacity(popOutTopScrimKey), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(const Offset(300, 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(popOutTopScrimKey), 1);
    expect(opacity(popOutBottomScrimKey), 1);
    final top = tester.getRect(find.byKey(popOutTopScrimKey));
    final bottom = tester.getRect(find.byKey(popOutBottomScrimKey));
    expect(top.top, 0);
    expect(top.width, 640);
    expect(top.height, kPopOutScrimHeight);
    expect(bottom.bottom, 400);
    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
