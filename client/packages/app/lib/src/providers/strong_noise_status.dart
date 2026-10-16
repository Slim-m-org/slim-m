// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether Strong noise suppression was asked for but is not running, so the
/// settings row can say so instead of leaving the member to guess.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'noise_suppression.dart';
import 'voice_flags.dart';

/// About 2 s of consecutive inactive polls at the gate's 50 ms interval.
const int kStrongInactivePolls = 40;

/// Active polls in a row before the note goes away, so one stray frame does
/// not flicker it.
const int kStrongActivePolls = 10;

/// Strong is the effective choice, a call is live and the mic is unmuted.
final _strongExpectedProvider = Provider.autoDispose<bool>((ref) {
  final choice = ref.watch(noiseSuppressionProvider);
  final spaceStrong =
      ref.watch(spaceStrongNoiseSuppressionProvider).valueOrNull ?? false;
  final flags = ref.watch(voiceFlagsProvider);
  return choice.isStrong(spaceStrong: spaceStrong) &&
      flags.state == VoiceSessionState.connected &&
      flags.microphoneEnabled;
});

class _StrongInactiveNotifier extends StateNotifier<bool> {
  _StrongInactiveNotifier(Ref ref) : super(false) {
    ref.listen<bool>(_strongExpectedProvider, (_, expected) {
      if (!expected) _reset();
    });
    ref.listen<AsyncValue<InputGateReading>>(inputGateReadingProvider, (
      _,
      next,
    ) {
      final reading = next.valueOrNull;
      if (reading == null || !ref.read(_strongExpectedProvider)) return;
      _add(reading.strongActive);
    });
  }

  int _inactive = 0;
  int _active = 0;

  void _reset() {
    _inactive = 0;
    _active = 0;
    state = false;
  }

  void _add(bool active) {
    if (active) {
      _inactive = 0;
      if (++_active >= kStrongActivePolls) state = false;
    } else {
      _active = 0;
      if (++_inactive >= kStrongInactivePolls) state = true;
    }
  }
}

final strongNoiseInactiveProvider =
    StateNotifierProvider.autoDispose<_StrongInactiveNotifier, bool>(
      _StrongInactiveNotifier.new,
    );
