// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message engine that plays nothing and logs what it was asked, and
/// a page of players over it, shared by the voice message suites.
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

Attachment voiceMessage(
  String id, {
  int seconds = 40,
  VoiceTranscript? transcript,
}) => Attachment(
  id: id,
  filename: 'voice-message.ogg',
  contentType: 'audio/ogg',
  size: 4,
  voice: VoiceInfo(
    duration: Duration(seconds: seconds),
    waveform: List.generate(64, (i) => (i * 4) % 256),
  ),
  transcript: transcript,
);

/// Players for [messages] in a column, over a fresh [FakePlayer]; a clip in
/// [unplayable] fails to load for as long as it stays in the set.
Future<FakePlayer> pumpVoicePlayers(
  WidgetTester tester,
  List<Attachment> messages, {
  Set<String> unplayable = const {},
  List<Override> extra = const [],
}) async {
  final player = FakePlayer();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...extra,
        voicePlayerFactoryProvider.overrideWithValue(() => player),
        attachmentBytesProvider.overrideWith(
          (ref, id) async => unplayable.contains(id)
              ? throw const TransportException('offline')
              : Uint8List.fromList([1, 2, 3, 4]),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Column(
            children: [
              for (final m in messages) VoiceMessagePlayer(attachment: m),
            ],
          ),
        ),
      ),
    ),
  );
  return player;
}
