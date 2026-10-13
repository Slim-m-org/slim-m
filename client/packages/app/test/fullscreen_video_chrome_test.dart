// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Full screen on desktop covers the display: the OS window goes fullscreen,
/// the app title bar steps aside, and the name row only shows on hover.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_chrome.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/title_bar.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'desktop/support/fake_desktop_window_port.dart';
import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

class _Call extends VoiceController {
  _Call(super.ref, FakeSession session) : super(session: session) {
    state = const VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.connected,
      participants: [_ada],
    );
  }
}

void main() {
  late FakeDesktopWindowPort port;

  setUp(() {
    port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.debugActivate(frameless: true);
    addTearDown(DesktopWindowShell.debugReset);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => _Call(ref, FakeSession()),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          builder: (context, child) => DesktopChrome(child: child!),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFullscreenVideo(
                context,
                identity: 'u-ada',
                label: "Ada's screen",
                kind: FullscreenVideoKind.screenShare,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the window goes fullscreen and the title bar steps aside', (
    tester,
  ) async {
    await open(tester);
    expect(port.fullScreen, isTrue);
    expect(find.byType(TitleBar), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(port.fullScreen, isFalse);
    expect(find.byType(TitleBar), findsOneWidget);
  });

  testWidgets('the name row shows on hover and hides when the pointer leaves', (
    tester,
  ) async {
    await open(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(const Offset(400, 400));
    await tester.pumpAndSettle();
    expect(find.text("Ada's screen"), findsOneWidget);

    await mouse.moveTo(const Offset(-10, -10));
    await tester.pumpAndSettle();
    expect(find.text("Ada's screen"), findsNothing);
  });
}
