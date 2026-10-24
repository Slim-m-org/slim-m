// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shared screen with sound carries its own volume control, on the share
/// tile and in the pop-out player, apart from the sharer's voice.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_view.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/features/voice/widgets/share_stage_grid.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/menu_gestures.dart';
import 'voice_controller_harness.dart';

class _SoundSession extends FakeSession {
  _SoundSession({required this.sound, this.onScreenVolume});

  final bool sound;
  final void Function(double volume)? onScreenVolume;

  @override
  bool hasScreenAudio(String identity) => sound;

  @override
  Future<void> setScreenVolumeFor(String identity, double volume) async =>
      onScreenVolume?.call(volume);
}

VoiceParticipant _sharer({bool isLocal = false}) => VoiceParticipant(
  identity: isLocal ? 'me' : 'u-ada',
  name: isLocal ? 'Me' : 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: isLocal,
  isScreenSharing: true,
);

Future<void> _pumpTile(
  WidgetTester tester, {
  required bool sound,
  required VoiceParticipant sharer,
  void Function(double volume)? onScreenVolume,
}) async {
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  final controller = harness.controllerWith(
    _SoundSession(sound: sound, onScreenVolume: onScreenVolume),
    voiceApi(),
  );
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        // The app chrome's own transparent Material, which a dialog's slider needs above it.
        builder: (context, child) =>
            Material(type: MaterialType.transparency, child: child),
        home: Scaffold(
          body: Builder(
            builder: (context) => SizedBox(
              width: 640,
              height: 360,
              child: shareStageTile(context, sharer, controller),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a share with sound shows its volume slider right in the menu', (
    tester,
  ) async {
    await _pumpTile(tester, sound: true, sharer: _sharer());

    await rightClickMenu(tester, find.byType(ScreenShareStage));

    expect(find.text('Stream volume'), findsOneWidget);
    expect(find.byType(AppSlider), findsOneWidget);
    expect(find.text("Ada's screen audio"), findsNothing);
  });

  testWidgets('dragging the menu slider sets that share\'s volume', (
    tester,
  ) async {
    final volumes = <double>[];
    await _pumpTile(
      tester,
      sound: true,
      sharer: _sharer(),
      onScreenVolume: volumes.add,
    );

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.drag(find.byType(AppSlider), const Offset(-60, 0));
    await tester.pumpAndSettle();

    expect(volumes, isNotEmpty);
    expect(volumes.last, lessThan(1));
  });

  testWidgets('the menu slider takes the arrow keys as soon as it opens', (
    tester,
  ) async {
    final volumes = <double>[];
    await _pumpTile(
      tester,
      sound: true,
      sharer: _sharer(),
      onScreenVolume: volumes.add,
    );

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(volumes, isNotEmpty);
    expect(volumes.last, lessThan(1));
  });

  testWidgets('a silent share offers no stream volume', (tester) async {
    await _pumpTile(tester, sound: false, sharer: _sharer());

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    expect(find.text('Stream volume'), findsNothing);
    expect(find.text('Full screen'), findsOneWidget);
  });

  testWidgets('your own share offers no stream volume', (tester) async {
    await _pumpTile(tester, sound: true, sharer: _sharer(isLocal: true));

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    expect(find.text('Stream volume'), findsNothing);
    expect(find.text('Full screen'), findsOneWidget);
  });

  for (final sound in [true, false]) {
    testWidgets('the pop-out player shows the stream volume: $sound', (
      tester,
    ) async {
      final harness = VoiceHarness();
      addTearDown(harness.dispose);
      harness.controllerWith(_SoundSession(sound: sound), voiceApi());
      tester.view.physicalSize = const Size(640, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const PopOutWindowView(
              feed: (
                identity: 'u-ada',
                name: 'Ada',
                kind: FeedKind.screenShare,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(AppSlider), sound ? findsOneWidget : findsNothing);
    });
  }
}
