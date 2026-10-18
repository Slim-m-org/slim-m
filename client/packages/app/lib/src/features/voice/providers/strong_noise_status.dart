// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether Strong noise suppression was asked for but is not running, so the
/// settings row can say so instead of leaving the member to guess.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'noise_suppression.dart';
import 'voice_flags.dart';

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
      _add(reading.strongActive, reading.step);
    });
  }

  final _tracker = StrongInactivityTracker();

  void _reset() {
    _tracker.reset();
    state = false;
  }

  void _add(bool active, Duration step) =>
      state = _tracker.add(strongActive: active, step: step);
}

final strongNoiseInactiveProvider =
    StateNotifierProvider.autoDispose<_StrongInactiveNotifier, bool>(
      _StrongInactiveNotifier.new,
    );
