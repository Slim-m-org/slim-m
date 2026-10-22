// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The floating music badge: wide windows only, while alone in the call, with
/// style pick, timeline, play/pause and a volume slider.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';
import 'package:slimm_app/src/audio/lounge_tracks.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/hold_music_badge.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'package:slimm_app/src/features/voice/providers/hold_music_controller.dart';

import '../../support/hold_playback_fake.dart';

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

VoiceParticipant _p(String id, {bool local = false}) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

final _roster = StateProvider<List<VoiceParticipant>>(
  (ref) => [_p('me', local: true)],
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required _Player player,
  double width = 1280,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      holdMusicPlayerProvider.overrideWithValue(player),
      voiceParticipantsProvider.overrideWith((ref) => ref.watch(_roster)),
    ],
  )..read(preferencesProvider);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Stack(children: [HoldMusicBadgeOverlay(bottom: 88)]),
        ),
      ),
    ),
  );
  container.read(voiceSettingsControllerProvider);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('shows on a wide window while alone, with play and the clock', (
    tester,
  ) async {
    final player = _Player();
    await _pump(tester, player: player);

    expect(find.bySemanticsLabel('Play music'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Music style')), findsOneWidget);
    expect(find.bySemanticsLabel('Music volume'), findsWidgets);
    expect(find.text('0:00 / -:--'), findsOneWidget);
  });

  testWidgets('a compact window keeps the dock entries instead', (
    tester,
  ) async {
    await _pump(tester, player: _Player(), width: 599);
    expect(find.bySemanticsLabel('Play music'), findsNothing);
  });

  testWidgets('it leaves when someone else joins', (tester) async {
    final container = await _pump(tester, player: _Player());
    container.read(_roster.notifier).state = [_p('me', local: true), _p('you')];
    await tester.pump();
    expect(find.bySemanticsLabel('Play music'), findsNothing);
  });

  testWidgets('play turns music on; a paused track shows play, keeps the '
      'setting on, and play resumes it', (tester) async {
    final container = await _pump(tester, player: _Player());
    await tester.tap(find.bySemanticsLabel('Play music'));
    await tester.pump();
    expect(
      container.read(voiceSettingsControllerProvider).holdMusicEnabled,
      isTrue,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.hold_music_enabled'), isTrue);
    expect(find.bySemanticsLabel('Pause music'), findsOneWidget);

    container.read(holdMusicPausedProvider.notifier).state = true;
    await tester.pump();
    expect(find.bySemanticsLabel('Play music'), findsOneWidget);
    expect(
      container.read(voiceSettingsControllerProvider).holdMusicEnabled,
      isTrue,
      reason: 'pausing is not turning hold music off',
    );

    await tester.tap(find.bySemanticsLabel('Play music'));
    await tester.pump();
    expect(container.read(holdMusicPausedProvider), isFalse);
    expect(find.bySemanticsLabel('Pause music'), findsOneWidget);
  });

  testWidgets('the style menu picks a style and starts the music', (
    tester,
  ) async {
    final container = await _pump(tester, player: _Player());
    await tester.tap(find.bySemanticsLabel(RegExp('^Music style')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jazz'));
    await tester.pumpAndSettle();

    final settings = container.read(voiceSettingsControllerProvider);
    expect(settings.holdMusicTrack, LoungeTrack.jazz);
    expect(settings.holdMusicEnabled, isTrue);
  });

  testWidgets('the timeline shows elapsed and total and seeks', (tester) async {
    final player = _Player();
    final container = await _pump(tester, player: player);
    await container
        .read(voiceSettingsControllerProvider.notifier)
        .setHoldMusicEnabled(true);
    player.playbackNotifier.value = const HoldPlayback(
      position: Duration(seconds: 5),
      duration: Duration(minutes: 2, seconds: 34),
    );
    await tester.pump();
    expect(find.text('0:05 / 2:34'), findsOneWidget);

    await tester.drag(find.byType(AppSlider).first, const Offset(40, 0));
    await tester.pump();
    expect(player.seeks, hasLength(1));
    expect(player.seeks.single, greaterThan(Duration.zero));
  });

  testWidgets('the volume slider unfolds, sets the level and persists it', (
    tester,
  ) async {
    final container = await _pump(tester, player: _Player());
    expect(find.byType(RotatedBox), findsNothing);
    await tester.tap(find.bySemanticsLabel('Music volume').first);
    await tester.pumpAndSettle();
    expect(find.byType(RotatedBox), findsOneWidget);

    // The thermometer fills upward: dragging up is louder.
    await tester.drag(
      find.descendant(
        of: find.byType(RotatedBox),
        matching: find.byType(AppSlider),
      ),
      const Offset(0, -60),
    );
    await tester.pump();
    final volume = container
        .read(voiceSettingsControllerProvider)
        .holdMusicVolume;
    expect(volume, greaterThan(0.2));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('slimm.voice.hold_music_volume'), volume);
  });
}
