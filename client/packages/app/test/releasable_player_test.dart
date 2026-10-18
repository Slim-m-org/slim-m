// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A ring or hold loop that has finished leaves no native player allocated.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';
import 'package:slimm_app/src/audio/releasable_player.dart';

class _Native {
  bool disposed = false;
}

void main() {
  test('nothing is allocated until the first use', () {
    final player = ReleasablePlayer<_Native>(_Native.new, (_) async {});
    expect(player.allocated, isFalse);
    player.current;
    expect(player.allocated, isTrue);
  });

  test(
    'release disposes the player and the next use builds a fresh one',
    () async {
      final player = ReleasablePlayer<_Native>(
        _Native.new,
        (p) async => p.disposed = true,
      );
      final first = player.current;

      await player.release();

      expect(first.disposed, isTrue);
      expect(player.allocated, isFalse);
      expect(player.current, isNot(same(first)));
    },
  );

  test('releasing an unused player is a no-op', () async {
    final player = ReleasablePlayer<_Native>(_Native.new, (_) async {});
    await player.release();
    expect(player.allocated, isFalse);
  });

  test(
    'a stop that disposes the player mid-start does not fail the start',
    () async {
      final output = _DisposedMidStart();
      final player = AudioPlayersHoldMusicPlayer(output: output);
      final started = player.start();
      await player.stop();
      output.opened.complete();
      await started;
    },
  );
}

class _DisposedMidStart implements HoldLoopOutput {
  final opened = Completer<void>();

  @override
  Future<void> play(String asset) async {
    await opened.future;
    throw StateError('player disposed');
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
