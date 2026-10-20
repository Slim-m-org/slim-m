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
  _SoundSession({required this.sound});

  final bool sound;

  @override
  bool hasScreenAudio(String identity) => sound;
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
}) async {
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  final controller = harness.controllerWith(
    _SoundSession(sound: sound),
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
  testWidgets('a share with sound opens its own screen audio volume', (
    tester,
  ) async {
    await _pumpTile(tester, sound: true, sharer: _sharer());

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.tap(find.text('Stream volume'));
    await tester.pumpAndSettle();

    expect(find.text("Ada's screen audio"), findsOneWidget);
    expect(find.text('Mute screen audio'), findsOneWidget);
    expect(find.text('Volume for Ada'), findsNothing);
  });

  testWidgets('the stream volume slider has focus when the popover opens', (
    tester,
  ) async {
    await _pumpTile(tester, sound: true, sharer: _sharer());

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.tap(find.text('Stream volume'));
    await tester.pumpAndSettle();

    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull);
    expect(
      find.descendant(
        of: find.byType(AppSlider),
        matching: find.byWidgetPredicate(
          (w) => w is Focus && w.focusNode == focus,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Escape closes the stream volume popover', (tester) async {
    await _pumpTile(tester, sound: true, sharer: _sharer());

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.tap(find.text('Stream volume'));
    await tester.pumpAndSettle();
    expect(find.text("Ada's screen audio"), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text("Ada's screen audio"), findsNothing);
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
