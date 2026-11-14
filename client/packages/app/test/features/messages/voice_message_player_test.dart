// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message on a row: play and pause, the played part of the waveform,
/// the clock, the speed, and one message playing at a time. The audio engine
/// is a fake, so nothing reaches a real device.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/voice_playback.dart';
import 'package:slimm_app/src/features/messages/widgets/voice_message_player.dart';
import 'package:slimm_app/src/widgets/voice_waveform.dart';
import 'package:slimm_design_system/design_system.dart';

class FakePlayer implements VoicePlayerBackend {
  final position = StreamController<Duration>.broadcast();
  final done = StreamController<void>.broadcast();
  final log = <String>[];
  double speed = 1;

  @override
  Stream<Duration> get positions => position.stream;
  @override
  Stream<void> get completed => done.stream;
  @override
  Future<void> play(Uint8List bytes, String mimeType, double speed) async {
    this.speed = speed;
    log.add('play ${bytes.length} $mimeType @$speed');
  }

  @override
  Future<void> pause() async => log.add('pause');
  @override
  Future<void> resume() async => log.add('resume');
  @override
  Future<void> seek(Duration position) async =>
      log.add('seek ${position.inMilliseconds}');
  @override
  Future<void> setSpeed(double speed) async {
    this.speed = speed;
    log.add('speed $speed');
  }

  @override
  Future<void> stop() async => log.add('stop');
  @override
  Future<void> dispose() async => log.add('dispose');
}

Attachment voiceMessage(String id, {int seconds = 40}) => Attachment(
  id: id,
  filename: 'voice-message.ogg',
  contentType: 'audio/ogg',
  size: 4,
  voice: VoiceInfo(
    duration: Duration(seconds: seconds),
    waveform: List.generate(64, (i) => (i * 4) % 256),
  ),
);

void main() {
  late FakePlayer player;

  Future<ProviderContainer> pump(
    WidgetTester tester,
    List<Attachment> messages, {
    Set<String> unplayable = const {},
  }) async {
    player = FakePlayer();
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voicePlayerFactoryProvider.overrideWithValue(() => player),
          attachmentBytesProvider.overrideWith(
            (ref, id) async => unplayable.contains(id)
                ? throw const TransportException('offline')
                : Uint8List.fromList([1, 2, 3, 4]),
          ),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              theme: buildTheme(Brightness.light, AppTokens.light),
              home: Scaffold(
                body: Column(
                  children: [
                    for (final m in messages) VoiceMessagePlayer(attachment: m),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    return container;
  }

  testWidgets('shows the length, and nothing plays until asked', (
    tester,
  ) async {
    await pump(tester, [voiceMessage('a')]);
    expect(find.text('0:40'), findsOneWidget);
    expect(player.log, isEmpty);
  });

  testWidgets('play fetches the clip once and pause and resume keep it', (
    tester,
  ) async {
    await pump(tester, [voiceMessage('a')]);
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
    await pump(tester, [voiceMessage('a')]);
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
    await pump(tester, [voiceMessage('a')]);
    final speed = find.byKey(const Key('voice-player-speed'));
    expect(find.text('1x'), findsOneWidget);
    await tester.tap(speed);
    await tester.pump();
    expect(find.text('1.5x'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    expect(player.speed, 1.5, reason: 'playback starts at the chosen speed');
    await tester.tap(speed);
    await tester.pump();
    expect(find.text('2x'), findsOneWidget);
    expect(player.speed, 2.0);
    await tester.tap(speed);
    await tester.pump();
    expect(find.text('1x'), findsOneWidget);
  });

  testWidgets('starting one message stops the one playing before it', (
    tester,
  ) async {
    await pump(tester, [voiceMessage('a'), voiceMessage('b')]);
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
    await pump(tester, [voiceMessage('a')]);
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
    await pump(
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
}
