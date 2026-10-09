// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why the mic and camera do nothing in this call, for the dock to say.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart' show meProvider;
import '../providers/voice_flags.dart';

const cannotSpeakReason = "You can't speak in this channel";
const timedOutReason = 'You are timed out';
const joinedMutedHint = 'Unmute to talk. This channel joins muted.';

/// Null when the token lets this member publish; otherwise the reason it cannot.
String? listenOnlyReason(WidgetRef ref, VoiceFlags voice) {
  if (voice.canPublish) return null;
  final until = ref.watch(meProvider).valueOrNull?.timedOutUntil;
  final timedOut =
      until != null && until > DateTime.now().millisecondsSinceEpoch;
  return timedOut ? timedOutReason : cannotSpeakReason;
}
