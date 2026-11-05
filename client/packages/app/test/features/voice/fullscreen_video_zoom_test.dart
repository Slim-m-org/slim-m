// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share opened full screen zooms with the wheel, the +/-/0 keys and a double click, and still closes on Escape.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';
import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);
const _level = Key('share-zoom-level');

Future<void> _open(WidgetTester tester, FullscreenVideoKind kind) async {
  tester.view.physicalSize = const Size(1400, 880);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FakeVoiceController(
            ref,
            session: FakeSession(),
            initial: const VoiceState(
              channelId: 'c-main',
              state: VoiceSessionState.connected,
              participants: [_ada],
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFullscreenVideo(
              context,
              identity: 'u-ada',
              label: "Ada's screen",
              kind: kind,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('the wheel zooms a full-screen share', (tester) async {
    await _open(tester, FullscreenVideoKind.screenShare);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(700, 440)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.pump();
    expect(find.byKey(_level), findsOneWidget);
  });

  testWidgets('the keys zoom it from the first frame and Escape still leaves', (
    tester,
  ) async {
    await _open(tester, FullscreenVideoKind.screenShare);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.pump();
    expect(find.byKey(_level), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.pump();
    expect(find.byKey(_level), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a double click toggles between fit and zoomed', (tester) async {
    await _open(tester, FullscreenVideoKind.screenShare);
    Future<void> doubleClick() async {
      await tester.tapAt(const Offset(700, 440));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(700, 440));
      await tester.pump(const Duration(milliseconds: 50));
    }

    await doubleClick();
    expect(find.byKey(_level), findsOneWidget);
    await doubleClick();
    expect(find.byKey(_level), findsNothing);
  });

  testWidgets('a camera opened full screen has no zoom', (tester) async {
    await _open(tester, FullscreenVideoKind.camera);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.pump();
    expect(find.byKey(_level), findsNothing);
  });
}
