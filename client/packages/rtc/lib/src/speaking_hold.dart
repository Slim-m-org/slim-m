// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a speaking ring lit for a moment after the SFU says someone
/// stopped, so the short gaps between words do not make it flicker now that
/// the SFU reports quickly. See docs/voice-input-gate.md.
library;

import 'voice_models.dart';

/// How long a ring stays lit after speech stops.
const Duration kSpeakingHold = Duration(milliseconds: 300);

class SpeakingHold {
  SpeakingHold({this.hold = kSpeakingHold, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Duration hold;
  final DateTime Function() _clock;
  final Map<String, DateTime> _lastSpoke = {};

  /// [roster] with anyone who spoke within [hold] still speaking, unless
  /// they are muted. The local participant is left as reported when
  /// [skipLocal], since the input gate already holds its own ring. Returns
  /// how long until the next held ring should drop, or null if none is held.
  (List<VoiceParticipant>, Duration?) apply(
    List<VoiceParticipant> roster, {
    bool skipLocal = false,
  }) {
    final now = _clock();
    Duration? recheck;
    final present = <String>{};
    final out = <VoiceParticipant>[];
    for (final p in roster) {
      present.add(p.identity);
      if (p.isSpeaking) {
        _lastSpoke[p.identity] = now;
        out.add(p);
        continue;
      }
      final last = _lastSpoke[p.identity];
      final left = last == null ? null : hold - now.difference(last);
      if (left == null ||
          left <= Duration.zero ||
          p.isMuted ||
          (skipLocal && p.isLocal)) {
        out.add(p);
        continue;
      }
      out.add(
        VoiceParticipant(
          identity: p.identity,
          name: p.name,
          isSpeaking: true,
          isMuted: p.isMuted,
          isLocal: p.isLocal,
          isScreenSharing: p.isScreenSharing,
          isCameraOn: p.isCameraOn,
          audioLevel: p.audioLevel,
        ),
      );
      if (recheck == null || left < recheck) recheck = left;
    }
    _lastSpoke.removeWhere((identity, _) => !present.contains(identity));
    return (out, recheck);
  }
}
