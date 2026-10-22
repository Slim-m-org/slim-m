// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stop that lands while a track is still opening must win, and a style
/// change while playing switches the music live.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';
import 'package:slimm_app/src/audio/lounge_tracks.dart';
import 'support/hold_playback_fake.dart';

class _Output with HoldPlaybackFake implements HoldLoopOutput {
  final calls = <String>[];
  Completer<void>? gate;

  @override
  Future<void> play(String asset) async {
    calls.add('play $asset');
    await gate?.future;
  }

  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> dispose() async {}
}

void main() {
  test('a stop while the track is opening silences it again', () async {
    final output = _Output()..gate = Completer<void>();
    final player = AudioPlayersHoldMusicPlayer(output: output);

    final started = player.start();
    await player.stop();
    output.gate!.complete();
    await started;

    expect(output.calls.last, 'stop');
  });

  test('start after a stop still plays', () async {
    final output = _Output();
    final player = AudioPlayersHoldMusicPlayer(output: output);

    await player.start();
    await player.stop();
    await player.start();

    expect(output.calls.where((c) => c.startsWith('play')), hasLength(2));
  });

  test('a new style plays straight away while music is on', () async {
    final output = _Output();
    final player = AudioPlayersHoldMusicPlayer(output: output);

    await player.start();
    await player.setTrack(LoungeTrack.jazz);

    expect(output.calls.last, 'play ${LoungeTrack.jazz.asset}');
  });

  test('a new style while stopped waits for the next start', () async {
    final output = _Output();
    final player = AudioPlayersHoldMusicPlayer(output: output);

    await player.setTrack(LoungeTrack.ambient);
    expect(output.calls, isEmpty);
    await player.start();
    expect(output.calls.single, 'play ${LoungeTrack.ambient.asset}');
  });
}
