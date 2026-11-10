// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop pop-out window: one camera or screen share in its own small
/// borderless window, with and without the pointer over it. Desktop only.
///
/// The video is the snapshot session's flat stand-in, since a test has no
/// live track; what is under review here is the window's own chrome.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_snapshot_fixtures.dart';
import '../support/fake_voice.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'app_chrome_support.dart';

const _window = Size(960, 540);
const _smallWindow = Size(480, 270);

const _ada = VoiceParticipant(
  identity: 'user-ada',
  name: 'Ada Lovelace',
  isSpeaking: true,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
  isCameraOn: true,
);

/// A share that carries sound, so the hover state shows the volume pill.
class _SoundSession extends VisibleSnapshotSession {
  @override
  bool hasScreenAudio(String identity) => true;
}

final _frame = PopOutFrame(
  onMoveStart: () {},
  onResizeStart: (_) {},
  onClose: () {},
);

Future<void> _popOut(
  WidgetTester tester, {
  required String state,
  required Size size,
  required FeedKind kind,
  bool hover = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FakeVoiceController(
          ref,
          initial: connectedCallState.copyWith(participants: const [_ada]),
          session: _SoundSession(),
        ),
      ),
    ],
  );
  Widget build(String theme) => UncontrolledProviderScope(
    container: fixture.container,
    child: RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(
          snapshotThemes[theme]!.brightness,
          snapshotThemes[theme]!.tokens,
        ),
        home: PopOutWindowView(
          feed: (identity: _ada.identity, name: _ada.name, kind: kind),
          frame: _frame,
        ),
      ),
    ),
  );

  await tester.pumpWidget(build('dark'));
  await tester.pump();
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  if (hover) {
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(size.center(Offset.zero));
  }
  // The reveal's fade starts on the frame after the hover, so it takes two.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  for (final theme in const ['dark', 'light']) {
    if (theme != 'dark') {
      await tester.pumpWidget(build(theme));
      await tester.pump(const Duration(milliseconds: 350));
    }
    final name = chromeName(
      'window-popout',
      state: state,
      viewport: 'desktop',
      theme: theme,
    );
    await expectSettled(tester, name);
    await writeSnapshot(tester, name);
    expect(tester.takeException(), isNull);
  }
  if (hover) await mouse.removePointer();
  await teardownFixture(tester, fixture.container, fixture.db);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    'camera',
    (tester) =>
        _popOut(tester, state: 'camera', size: _window, kind: FeedKind.camera),
  );

  testWidgets(
    'share',
    (tester) => _popOut(
      tester,
      state: 'share',
      size: _window,
      kind: FeedKind.screenShare,
    ),
  );

  testWidgets(
    'hover controls',
    (tester) => _popOut(
      tester,
      state: 'hover-controls',
      size: _window,
      kind: FeedKind.screenShare,
      hover: true,
    ),
  );

  testWidgets(
    'small window',
    (tester) => _popOut(
      tester,
      state: 'small-window',
      size: _smallWindow,
      kind: FeedKind.screenShare,
      hover: true,
    ),
  );
}
