// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What was last pushed to each person's platform audio, so a repeat pass can
/// skip it, without ever trusting that across a change of track.
library;

import 'local_audio.dart';

class _Entry {
  _Entry(Object track, this.trackId) : track = WeakReference(track);

  final WeakReference<Object> track;
  final String trackId;
  double? volume;
  bool? forwarding;
}

/// Keyed by person and channel, valid only for the track object and native
/// track id it was recorded against. A receiver replaced under the same Dart
/// object is caught by [forget], which the room events call.
class AudioApplyCache {
  final Map<(String, LocalAudioChannel), _Entry> _entries = {};

  _Entry _entryFor(LocalAudioRef ref) {
    final key = (ref.identity, ref.channel);
    final entry = _entries[key];
    if (entry != null &&
        identical(entry.track.target, ref.track) &&
        entry.trackId == ref.trackId) {
      return entry;
    }
    return _entries[key] = _Entry(ref.track, ref.trackId);
  }

  double? volumeOf(LocalAudioRef ref) => _entryFor(ref).volume;

  void setVolume(LocalAudioRef ref, double? volume) =>
      _entryFor(ref).volume = volume;

  bool? forwardingOf(LocalAudioRef ref) => _entryFor(ref).forwarding;

  void setForwarding(LocalAudioRef ref, bool forwarding) =>
      _entryFor(ref).forwarding = forwarding;

  /// Drops what is believed about [identity] (everyone when null). With
  /// [volumeOnly] the SFU forwarding state is kept: only the gain is suspect.
  void forget({
    String? identity,
    LocalAudioChannel? channel,
    bool volumeOnly = false,
  }) {
    for (final key in _entries.keys.toList()) {
      if (identity != null && key.$1 != identity) continue;
      if (channel != null && key.$2 != channel) continue;
      if (volumeOnly) {
        _entries[key]!.volume = null;
      } else {
        _entries.remove(key);
      }
    }
  }
}
