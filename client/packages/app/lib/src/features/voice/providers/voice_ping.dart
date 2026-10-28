// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Round trip to the voice server, for the call header and the connection dot.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_controller.dart';
import 'voice_health.dart';

/// Whole milliseconds, or null outside a call and before the first sample.
final voicePingProvider = StateNotifierProvider<ListenableState<int?>, int?>(
  (ref) => ListenableState(
    ref.watch(voiceControllerProvider.notifier).health.pingMs,
  ),
);

enum VoicePingTier { good, fair, poor }

VoicePingTier voicePingTier(int ms) => ms < 100
    ? VoicePingTier.good
    : ms < 200
    ? VoicePingTier.fair
    : VoicePingTier.poor;

String voicePingLabel(int ms) => '$ms ms';
