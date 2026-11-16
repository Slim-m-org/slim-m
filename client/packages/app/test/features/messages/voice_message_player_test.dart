// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message on a row: play and pause, the played part of the waveform,
/// the clock, the speed, one message playing at a time, and what it says when
/// it cannot play. The audio engine is a fake, so nothing reaches a real device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/voice_playback.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/widgets/voice_waveform.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_player_fakes.dart';

void main() {
  late FakePlayer player;

  testWidgets('shows the length, and nothing plays until asked', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    expect(find.text('0:40'), findsOneWidget);
    expect(player.log, isEmpty);
  });

  testWidgets('play fetches the clip once and pause and resume keep it', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    expect(player.log, ['play 4 audio/ogg @1.0']);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(player.log.skip(1), ['pause', 'resume']);
  });

  testWidgets('the position fills the waveform and runs the clock', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    player.position.add(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump();
    expect(find.text('0:10'), findsOneWidget);
    final wave = tester.widget<VoiceWaveform>(
      find.byWidgetPredicate((w) => w is VoiceWaveform),
    );
    expect(wave.progress, closeTo(0.25, 0.001));
    player.done.add(null);
    await tester.pump();
    await tester.pump();
    expect(find.text('0:40'), findsOneWidget, reason: 'back to its length');
  });

  testWidgets('the speed button cycles 1x, 1.5x, 2x and reaches the engine', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    final speed = find.byKey(const Key('voice-player-speed'));
    expect(find.text('1x').hitTestable(), findsOneWidget);
    await tester.tap(speed);
    await tester.pump();
    expect(find.text('1.5x').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    expect(player.speed, 1.5, reason: 'playback starts at the chosen speed');
    await tester.tap(speed);
    await tester.pump();
    expect(find.text('2x').hitTestable(), findsOneWidget);
    expect(player.speed, 2.0);
    await tester.tap(speed);
    await tester.pump();
    expect(find.text('1x').hitTestable(), findsOneWidget);
  });

  testWidgets('starting one message stops the one playing before it', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [
      voiceMessage('a'),
      voiceMessage('b'),
    ]);
    await tester.tap(find.byTooltip('Play').first);
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget, reason: 'only one plays');
    expect(player.log.where((l) => l.startsWith('play')).length, 2);
  });

  testWidgets('tapping the waveform seeks in proportion to the width', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    final rect = tester.getRect(find.byKey(const Key('voice-player-wave')));
    await tester.tapAt(Offset(rect.left + rect.width / 2, rect.center.dy));
    await tester.pump();
    final seek = player.log.last;
    expect(seek, startsWith('seek '));
    expect(int.parse(seek.split(' ').last), closeTo(20000, 800));
  });

  testWidgets('a message that cannot play says so on its own row only', (
    tester,
  ) async {
    player = await pumpVoicePlayers(
      tester,
      [voiceMessage('a'), voiceMessage('b')],
      unplayable: {'a'},
    );
    await tester.tap(find.byTooltip('Play').first);
    await tester.pump();
    await tester.pump();
    final error = find.text('The voice message could not be played.');
    expect(error, findsOneWidget);
    expect(
      tester.getCenter(error).dy,
      lessThan(tester.getCenter(find.byTooltip('Play').last).dy),
      reason: "under the first message's player, above the second's",
    );
  });

  testWidgets('a failure offers Retry, which plays once the clip loads', (
    tester,
  ) async {
    final unplayable = {'a'};
    player = await pumpVoicePlayers(tester, [
      voiceMessage('a'),
    ], unplayable: unplayable);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    expect(find.text('The voice message could not be played.'), findsOneWidget);
    unplayable.clear();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(player.log, ['play 4 audio/ogg @1.0']);
    expect(find.text('The voice message could not be played.'), findsNothing);
  });

  testWidgets('a failure can be dismissed', (tester) async {
    player = await pumpVoicePlayers(
      tester,
      [voiceMessage('a')],
      unplayable: {'a'},
    );
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('The voice message could not be played.'), findsNothing);
  });

  testWidgets('in a call on iOS the player says why, as a note not an error', (
    tester,
  ) async {
    player = await pumpVoicePlayers(
      tester,
      [voiceMessage('a')],
      extra: [
        voicePlaybackProvider.overrideWith(() => VoicePlayback(ios: true)),
        voiceFlagsProvider.overrideWithValue(
          const VoiceFlags(channelId: 'lounge'),
        ),
      ],
    );
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    final note = find.text('Leave the call to play a voice message.');
    expect(note, findsOneWidget);
    expect(
      tester.widget<Text>(note).style?.color,
      AppTokens.light.textSecondary,
    );
    expect(find.text('Retry'), findsNothing);
  });
}
