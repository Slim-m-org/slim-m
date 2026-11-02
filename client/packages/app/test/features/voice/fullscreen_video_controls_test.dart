// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Full screen video carries the call controls that matter while watching:
/// the share's volume, mute and deafen, and never a one-tap Leave.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_app/src/features/voice/widgets/stream_controls_reveal.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';
import 'voice_controller_harness.dart';

// A fixed run of frames long enough for a menu or fade to finish, without waiting on a ticker that may never stop.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

class _SoundSession extends FakeSession {
  @override
  bool hasScreenAudio(String identity) => true;
}

class _SilentSession extends FakeSession {
  @override
  bool hasScreenAudio(String identity) => false;
}

VoiceParticipant _ada({bool isLocal = false, bool camera = false}) =>
    VoiceParticipant(
      identity: isLocal ? 'me' : 'u-ada',
      name: 'Ada',
      isSpeaking: false,
      isMuted: false,
      isLocal: isLocal,
      isScreenSharing: !camera,
      isCameraOn: camera,
    );

Future<FakeVoiceController> _open(
  WidgetTester tester, {
  bool sound = true,
  bool isLocal = false,
  bool camera = false,
  Size window = const Size(1200, 800),
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ada = _ada(isLocal: isLocal, camera: camera);
  late FakeVoiceController controller;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => controller = FakeVoiceController(
            ref,
            recording: true,
            session: sound ? _SoundSession() : _SilentSession(),
            initial: VoiceState(
              channelId: 'c-main',
              state: VoiceSessionState.connected,
              participants: [ada],
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
              identity: ada.identity,
              label: "Ada's screen",
              kind: camera
                  ? FullscreenVideoKind.camera
                  : FullscreenVideoKind.screenShare,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return controller;
}

final _mic = find.byIcon(AppIcons.mic);
final _deafen = find.byIcon(AppIcons.headphones);
final _slider = find.bySubtype<AppSlider>();

void main() {
  testWidgets('a remote share with sound offers volume, mute and deafen', (
    tester,
  ) async {
    final controller = await _open(tester);
    expect(_slider, findsOneWidget);
    expect(_mic, findsOneWidget);
    expect(_deafen, findsOneWidget);

    await tester.tap(_mic);
    await tester.tap(_deafen);
    expect(controller.calls, ['mute', 'deafen']);
  });

  testWidgets('there is no one-tap Leave on a video you are only watching', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byIcon(AppIcons.leaveCall), findsNothing);
    expect(find.bySemanticsLabel('Leave call'), findsNothing);
  });

  for (final (name, sound, isLocal, camera) in [
    ('a silent share', false, false, false),
    ('your own share', true, true, false),
    ('a camera', true, false, true),
  ]) {
    testWidgets('$name has no volume but keeps mute and deafen', (
      tester,
    ) async {
      await _open(tester, sound: sound, isLocal: isLocal, camera: camera);
      expect(_slider, findsNothing);
      expect(_mic, findsOneWidget);
      expect(_deafen, findsOneWidget);
    });
  }

  testWidgets('the controls sit centred along the bottom edge', (tester) async {
    await _open(tester, sound: false);
    final mic = tester.getRect(_mic);
    final deafen = tester.getRect(_deafen);
    const window = Size(1200, 800);
    expect(mic.bottom, lessThan(window.height));
    expect(window.height - deafen.bottom, lessThan(48));
    expect(
      ((mic.left + deafen.right) / 2 - window.width / 2).abs(),
      lessThan(8),
    );
  });

  testWidgets('dragging the volume holds the header and the controls up', (
    tester,
  ) async {
    await _open(tester);
    final drag = await tester.startGesture(tester.getCenter(_slider));
    await drag.moveBy(const Offset(-40, 0));
    await tester.pump(kStreamControlsTouchHold * 2);
    expect(find.text("Ada's screen"), findsOneWidget);
    expect(_mic, findsOneWidget);

    await drag.up();
    await tester.pump(kStreamControlsTouchHold + const Duration(seconds: 1));
    await tester.pump();
    expect(find.text("Ada's screen"), findsNothing);
    expect(_mic, findsNothing);
  });

  testWidgets('on a phone mute and deafen are 44 point targets', (
    tester,
  ) async {
    await _open(tester, window: const Size(390, 844));
    for (final icon in [AppIcons.mic, AppIcons.headphones]) {
      final size = tester.getSize(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.bySubtype<AppIconButton>(),
        ),
      );
      expect(size.width, greaterThanOrEqualTo(AppSizes.rowTouch));
      expect(size.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    }
  });
}
