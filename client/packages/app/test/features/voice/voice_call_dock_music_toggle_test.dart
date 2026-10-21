// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's "music while alone" button: shown only while you are the
/// sole participant, and it flips the persisted setting Voice settings owns.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';
import 'package:slimm_app/src/audio/lounge_tracks.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/canvas_call_dock_fixtures.dart';
import 'voice_call_controls_harness.dart';

const _connected = VoiceFlags(state: VoiceSessionState.connected);
const _on = 'Pause music (Lofi)';
const _off = 'Play music while alone';

class _FakePlayer implements HoldMusicPlayer {
  @override
  Future<void> setTrack(LoungeTrack track) async {}

  final calls = <String>[];

  @override
  Future<void> start() async => calls.add('start');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> dispose() async {}
}

final _player = _FakePlayer();

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
  double width = 800,
  bool touch = false,
  String? canvasChannelId,
}) async {
  SharedPreferences.setMockInitialValues({});
  _player.calls.clear();
  return pumpVoiceCallDock(
    tester,
    _connected,
    width: width,
    touch: touch,
    canvasChannelId: canvasChannelId,
    extraOverrides: [
      holdMusicPlayerProvider.overrideWithValue(_player),
      voiceParticipantsProvider.overrideWith((ref) => ref.watch(_roster)),
    ],
  );
}

/// The music is either its own button or, on a dock too narrow for one, rows in the mic's long-press menu.
Future<void> _expectMusicReachable(WidgetTester tester) async {
  if (find.bySemanticsLabel(_off).evaluate().isNotEmpty) return;
  await tester.longPress(find.bySemanticsLabel(RegExp('^Mute')));
  await tester.pumpAndSettle();
  expect(find.text('Play music'), findsOneWidget);
}

void main() {
  testWidgets('alone, the dock offers the music toggle and it persists', (
    tester,
  ) async {
    final container = await _pump(tester);
    container.read(voiceSettingsControllerProvider);

    expect(find.bySemanticsLabel(_off), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(_off));
    await tester.pump();

    expect(
      container.read(voiceSettingsControllerProvider).holdMusicEnabled,
      isTrue,
    );
    expect(find.bySemanticsLabel(_on), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.hold_music_enabled'), isTrue);

    await tester.tap(find.bySemanticsLabel(_on));
    await tester.pump();
    expect(
      container.read(voiceSettingsControllerProvider).holdMusicEnabled,
      isFalse,
    );
  });

  testWidgets('it disappears when someone else joins', (tester) async {
    final container = await _pump(tester);
    expect(find.bySemanticsLabel(_off), findsOneWidget);

    container.read(_roster.notifier).state = [_p('me', local: true), _p('you')];
    await tester.pump();

    expect(find.bySemanticsLabel(_off), findsNothing);
    expect(find.bySemanticsLabel(_on), findsNothing);
  });

  testWidgets('at 360 with no canvas the row still folds', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpVoiceCallDock(
      tester,
      _connected,
      width: 360,
      touch: true,
      session: InertSession(supportsAudioOutputSelection: true),
      extraOverrides: [
        voiceParticipantsProvider.overrideWithValue([_p('me', local: true)]),
      ],
    );

    expect(tester.takeException(), isNull);
    await _expectMusicReachable(tester);
  });

  for (final width in [360.0, 440.0, 720.0, 1000.0]) {
    testWidgets('with the canvas open at $width the music button fits', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final dock = await pumpCanvasCallDock(
        tester,
        withCall: true,
        canvas: buildCanvasDockData(),
        width: width,
        touch: width < 400,
        compact: width < 400,
      );
      dock.session!.emitParticipants([_p('me', local: true)]);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      await _expectMusicReachable(tester);
    });
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('at $width the row folds instead of overflowing', (
      tester,
    ) async {
      await _pump(tester, width: width, touch: true, canvasChannelId: 'c1');

      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);
      await _expectMusicReachable(tester);
    });
  }

  testWidgets('the music options pick a style, turning music on with it', (
    tester,
  ) async {
    final container = await _pump(tester);
    container.read(voiceSettingsControllerProvider);
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Music options'));
    await tester.pumpAndSettle();
    expect(find.text('STYLE'), findsOneWidget);
    await tester.tap(find.text('Jazz'));
    await tester.pumpAndSettle();

    final settings = container.read(voiceSettingsControllerProvider);
    expect(settings.holdMusicTrack, LoungeTrack.jazz);
    expect(settings.holdMusicEnabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('slimm.voice.hold_music_track'), 'jazz');
    expect(find.bySemanticsLabel('Pause music (Jazz)'), findsOneWidget);
  });
}
