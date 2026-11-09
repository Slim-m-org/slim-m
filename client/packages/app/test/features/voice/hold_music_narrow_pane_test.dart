// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pane much narrower than its window (the canvas beside the rail): when the
/// floating music badge has no room there, the dock carries the music instead
/// of leaving nothing to pause it with.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';
import 'package:slimm_app/src/audio/lounge_tracks.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_call_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane_overlays.dart';
import 'package:slimm_app/src/features/members/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/features/modules/widgets/dock_height_reporter.dart';
import 'package:slimm_app/src/features/voice/providers/hold_music_actions.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/hold_music_badge.dart';
import 'package:slimm_app/src/providers/dock_reservation.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/canvas_call_dock_fixtures.dart';
import '../../support/hold_playback_fake.dart';
import 'fake_voice_session.dart';

class _Player with HoldPlaybackFake implements HoldMusicPlayer {
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setTrack(LoungeTrack track) async {}
  @override
  Future<void> dispose() async {}
}

const _me = VoiceParticipant(
  identity: 'me',
  name: 'me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

ProviderContainer _container({double dockWidth = 0}) {
  SharedPreferences.setMockInitialValues({});
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      channelBotUiProvider.overrideWith((ref, _) async => const []),
      holdMusicPlayerProvider.overrideWithValue(_Player()),
      voiceParticipantsProvider.overrideWithValue(const [_me]),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
      if (dockWidth > 0) bottomDockWidthProvider.overrideWith((_) => dockWidth),
    ],
  )..read(preferencesProvider);
  addTearDown(container.dispose);
  container.listen(channelBotUiProvider('c1'), (_, _) {});
  return container;
}

Future<void> _pumpPane(
  WidgetTester tester,
  ProviderContainer container, {
  required double window,
  required double pane,
  required Widget Function(ProviderContainer) children,
}) async {
  tester.view.physicalSize = Size(window, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: pane,
              child: Stack(children: [children(container)]),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// The badge measures itself after a frame and publishes after another, and the dock follows.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// The canvas pane's own pair: the call-and-canvas dock at the bottom, the badge over it.
Widget _canvasDockAndBadge(ProviderContainer container) => Stack(
  children: [
    Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s12),
        child: DockHeightReporter(
          child: CanvasCallDock(
            call: CallDockData(
              voice: connectedVoiceState,
              controller: container.read(voiceControllerProvider.notifier),
              channelId: 'c1',
            ),
            canvas: buildCanvasDockData(),
          ),
        ),
      ),
    ),
    const CanvasMusicBadge(),
  ],
);

/// The music is either its own button or, on a dock too narrow for one, rows in the mic's long-press menu.
Future<void> _expectMusicReachable(WidgetTester tester) async {
  if (find.bySemanticsLabel('Play music while alone').evaluate().isNotEmpty) {
    return;
  }
  await tester.longPress(find.bySemanticsLabel(RegExp('^Mute')));
  await _settle(tester);
  expect(find.text('Play music'), findsOneWidget);
}

void main() {
  testWidgets('a pane too narrow for the badge hands the music to the dock', (
    tester,
  ) async {
    final container = _container();
    await _pumpPane(
      tester,
      container,
      window: 960,
      pane: 680,
      children: _canvasDockAndBadge,
    );

    expect(find.bySubtype<HoldMusicBadge>(), findsNothing);
    expect(container.read(holdMusicBadgeAsideProvider), isTrue);
    await _expectMusicReachable(tester);
  });

  testWidgets('a pane with room keeps the badge and the dock carries none', (
    tester,
  ) async {
    final container = _container();
    await _pumpPane(
      tester,
      container,
      window: 1600,
      pane: 1600,
      children: _canvasDockAndBadge,
    );

    expect(find.bySubtype<HoldMusicBadge>(), findsOneWidget);
    expect(container.read(holdMusicBadgeAsideProvider), isFalse);
    expect(find.bySemanticsLabel('Play music while alone'), findsNothing);
    expect(find.bySemanticsLabel('Music options'), findsNothing);
  });

  testWidgets('the dock lets go of the music when the pane widens again', (
    tester,
  ) async {
    final container = _container();
    await _pumpPane(
      tester,
      container,
      window: 960,
      pane: 680,
      children: _canvasDockAndBadge,
    );
    expect(container.read(holdMusicBadgeAsideProvider), isTrue);

    await _pumpPane(
      tester,
      container,
      window: 1600,
      pane: 1600,
      children: _canvasDockAndBadge,
    );
    expect(find.bySubtype<HoldMusicBadge>(), findsOneWidget);
    expect(container.read(holdMusicBadgeAsideProvider), isFalse);
  });

  testWidgets('the dock lets go of the music when the badge leaves', (
    tester,
  ) async {
    final container = _container(dockWidth: 650);
    await _pumpPane(
      tester,
      container,
      window: 960,
      pane: 680,
      children: (_) =>
          const HoldMusicBadgeOverlay(fallbackBottom: 88, dockHeight: 64),
    );
    expect(container.read(holdMusicBadgeAsideProvider), isTrue);

    await _pumpPane(
      tester,
      container,
      window: 960,
      pane: 680,
      children: (_) => const SizedBox.shrink(),
    );
    expect(container.read(holdMusicBadgeAsideProvider), isFalse);
  });
}
