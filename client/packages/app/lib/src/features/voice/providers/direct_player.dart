// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The viewer's own player for direct play, as far as the controller needs it.
///
/// A port rather than `media_kit`'s `Player` itself so the controller's
/// decisions can be tested without libmpv or a GL texture, the same split the
/// attachment player makes. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'package:flutter/widgets.dart';

abstract interface class DirectPlayer {
  Duration get position;

  /// Whether the player is currently set to play, not whether frames are moving.
  bool get isPlaying;
  bool get isBuffering;

  /// Opens [url] paused at [start]; throws if it cannot be opened.
  Future<void> open(String url, Map<String, String> headers, Duration start);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);

  /// The picture, sized by its parent.
  Widget buildVideo();
  Future<void> dispose();
}
