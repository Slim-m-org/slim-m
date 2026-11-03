// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this device is playing right now, for rich presence (decision 0044).
///
/// Linux reads MPRIS over D-Bus and Windows reads the system media transport
/// controls through a method channel. Everywhere else [createNowPlayingSource]
/// is null: web has no such API and macOS has no supported one (decision 0044).
library;

import 'now_playing_stub.dart' if (dart.library.io) 'now_playing_io.dart'
    as impl;

/// One track a local player reports as playing.
class NowPlaying {
  const NowPlaying({
    required this.title,
    this.artist,
    this.source,
    this.artUrl,
    this.positionMs,
    this.durationMs,
    this.sampledAtMs,
  });

  final String title;
  final String? artist;

  /// The player's own name ("Spotify", "Mozilla Firefox"), when it gives one.
  final String? source;

  /// A cover image address the player reported. Not yet vetted: whoever
  /// shares it is responsible for refusing anything but a known host.
  final String? artUrl;

  /// Playback position at [sampledAtMs] and the track length, when the player
  /// reports them. Part of equality, so a seek re-emits and a steady poll does not.
  final int? positionMs;
  final int? durationMs;
  final int? sampledAtMs;

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      other.title == title &&
      other.artist == artist &&
      other.source == source &&
      other.artUrl == artUrl &&
      other.positionMs == positionMs &&
      other.durationMs == durationMs &&
      other.sampledAtMs == sampledAtMs;

  @override
  int get hashCode => Object.hash(
        title,
        artist,
        source,
        artUrl,
        positionMs,
        durationMs,
        sampledAtMs,
      );
}

/// A local player's playback state.
///
/// Listening starts the source (a D-Bus connection, say) and cancelling stops
/// it, so a source nobody listens to costs and reads nothing. Emits null when
/// nothing is playing, and only on change.
abstract interface class NowPlayingSource {
  Stream<NowPlaying?> watch();
}

/// The source for this platform, or null when there is none.
NowPlayingSource? createNowPlayingSource() => impl.createNowPlayingSource();
