// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The graded correction and the two reasons to give up, from decision 0050
/// section 6. See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/direct_play_corrector.dart';

final _t0 = DateTime.utc(2026, 10, 31, 20);

Correction _look(
  DirectPlayCorrector c, {
  required int errorMs,
  int epoch = 1,
  bool playing = true,
  bool stuck = false,
  Duration at = Duration.zero,
}) => c.step(
  target: const Duration(minutes: 10) + Duration(milliseconds: errorMs),
  actual: const Duration(minutes: 10),
  epoch: epoch,
  roomPlaying: playing,
  stuck: stuck,
  now: _t0.add(at),
);

void main() {
  test('under a quarter second does nothing', () {
    final c = DirectPlayCorrector();
    expect(_look(c, errorMs: 240), isA<NoCorrection>());
    expect(_look(c, errorMs: -240), isA<NoCorrection>());
  });

  test(
    'a quarter second to two seconds shifts the rate by 5 percent, toward the room',
    () {
      final behind = _look(DirectPlayCorrector(), errorMs: 1500);
      expect((behind as SetRate).rate, closeTo(1.05, 1e-9));
      final ahead = _look(DirectPlayCorrector(), errorMs: -1500);
      expect((ahead as SetRate).rate, closeTo(0.95, 1e-9));
    },
  );

  test(
    'a rate correction runs until the error closes and then returns to 1.0',
    () {
      final c = DirectPlayCorrector();
      expect(_look(c, errorMs: 800), isA<SetRate>());
      expect(
        _look(c, errorMs: 500, at: const Duration(seconds: 1)),
        isA<NoCorrection>(),
      );
      expect(
        _look(c, errorMs: 120, at: const Duration(seconds: 2)),
        isA<NoCorrection>(),
      );
      final done = _look(c, errorMs: 30, at: const Duration(seconds: 3));
      expect((done as SetRate).rate, 1.0);
    },
  );

  test('past two seconds it seeks to the room', () {
    final seek = _look(DirectPlayCorrector(), errorMs: 2500);
    expect(
      (seek as SeekTo).position,
      const Duration(minutes: 10, milliseconds: 2500),
    );
  });

  test(
    'an epoch change seeks even when the error is small, and is not counted against the player',
    () {
      final c = DirectPlayCorrector();
      _look(c, errorMs: 0);
      for (var i = 0; i < 5; i++) {
        expect(
          _look(
            c,
            errorMs: 100,
            epoch: 2 + i,
            at: Duration(seconds: i),
          ),
          isA<SeekTo>(),
        );
      }
    },
  );

  test(
    'three corrections inside a minute give up, and a quiet minute forgives',
    () {
      final c = DirectPlayCorrector();
      expect(_look(c, errorMs: 5000, at: Duration.zero), isA<SeekTo>());
      expect(
        _look(c, errorMs: 5000, at: const Duration(seconds: 20)),
        isA<SeekTo>(),
      );
      final third = _look(c, errorMs: 5000, at: const Duration(seconds: 40));
      expect((third as GiveUp).reason, GiveUpReason.drifting);

      final patient = DirectPlayCorrector();
      _look(patient, errorMs: 5000);
      _look(patient, errorMs: 5000, at: const Duration(seconds: 30));
      expect(
        _look(patient, errorMs: 5000, at: const Duration(seconds: 70)),
        isA<SeekTo>(),
      );
    },
  );

  test('a stall over ten seconds gives up and a shorter one does not', () {
    final c = DirectPlayCorrector();
    expect(_look(c, errorMs: 0, stuck: true), isA<NoCorrection>());
    expect(
      _look(c, errorMs: 0, stuck: true, at: const Duration(seconds: 9)),
      isA<NoCorrection>(),
    );
    final out = _look(
      c,
      errorMs: 0,
      stuck: true,
      at: const Duration(seconds: 11),
    );
    expect((out as GiveUp).reason, GiveUpReason.stalled);
  });

  test('a stall that clears starts the clock again', () {
    final c = DirectPlayCorrector();
    _look(c, errorMs: 0, stuck: true);
    _look(c, errorMs: 0, at: const Duration(seconds: 8));
    expect(
      _look(c, errorMs: 0, stuck: true, at: const Duration(seconds: 15)),
      isA<NoCorrection>(),
    );
  });

  test('a paused room is held by seeking, never by speeding up toward it', () {
    final c = DirectPlayCorrector();
    final held = _look(c, errorMs: 1000, playing: false);
    expect(held, isA<SeekTo>());
    expect(_look(c, errorMs: 100, playing: false), isA<NoCorrection>());
  });
}
