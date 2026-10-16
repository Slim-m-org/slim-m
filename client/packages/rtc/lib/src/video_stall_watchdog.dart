// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Notices a remote video that stopped decoding while it should be playing,
/// and walks it through recovery before giving up, so a frozen tile says so
/// instead of showing a stale frame forever.
library;

import 'package:flutter/foundation.dart';

/// What a tile should show about its video beyond the picture itself.
enum VideoTileHealth {
  /// Frames are arriving, or the video is not expected to play right now.
  playing,

  /// The server paused the stream (bandwidth or layer allocation).
  paused,

  /// Frames stopped while the video should be playing; recovery is running.
  stalled,

  /// Recovery ran out of steps and frames still did not come back.
  stopped,
}

/// One recovery attempt, tried in this order.
enum VideoStallStep { switchLayer, resubscribe }

/// One remote video at one sample.
class VideoStallReading {
  const VideoStallReading({
    required this.key,
    required this.framesDecoded,
    required this.expectPlaying,
    this.paused = false,
  });

  /// The tile key, `<kind>:<identity>` as the subscription culler uses.
  final String key;

  /// The receiver's decoded-frame count, or null when stats have none yet.
  final int? framesDecoded;

  /// Subscribed, unmuted, visible and not paused: frames are owed.
  final bool expectPlaying;

  /// The server paused this stream.
  final bool paused;
}

/// One remote video publication as the watchdog needs to see it.
typedef StallPublication = ({
  String key,
  bool subscribed,
  bool muted,
  bool active,
  int? framesDecoded,
});

/// Turns publications into readings. [seenActive] remembers which keys have
/// been active: a publication starts out "paused" until the server first says
/// otherwise, so only a pause after that counts. [interest] is what some
/// surface wants shown, null meaning every tile.
List<VideoStallReading> stallReadings(
  Iterable<StallPublication> publications, {
  required Set<String>? interest,
  required Set<String> seenActive,
}) =>
    [
      for (final pub in publications)
        VideoStallReading(
          key: pub.key,
          framesDecoded: pub.framesDecoded,
          paused: !pub.active && pub.subscribed && seenActive.contains(pub.key),
          expectPlaying: pub.subscribed &&
              !pub.muted &&
              pub.active &&
              (interest == null || interest.contains(pub.key)),
        ),
    ];

class _Track {
  int? frames;
  DateTime since = DateTime.fromMillisecondsSinceEpoch(0);
  int nextStep = 0;
  DateTime? lastStepAt;

  void progressed(DateTime now, int? framesDecoded) {
    frames = framesDecoded;
    since = now;
    nextStep = 0;
    lastStepAt = null;
  }
}

class VideoStallWatchdog {
  VideoStallWatchdog({
    required this.recover,
    DateTime Function()? clock,
    this.stallAfter = const Duration(seconds: 3),
    this.stepGap = const Duration(seconds: 4),
  }) : _clock = clock ?? DateTime.now;

  /// Asked to run [VideoStallStep] for the tile with [key].
  final void Function(String key, VideoStallStep step) recover;

  /// How long frames may stand still before it counts as a stall.
  final Duration stallAfter;

  /// How long one recovery step gets before the next is tried.
  final Duration stepGap;

  final DateTime Function() _clock;
  final _tracks = <String, _Track>{};
  final ValueNotifier<Map<String, VideoTileHealth>> health =
      ValueNotifier(const {});

  /// Folds one round of readings in; tiles missing from it are forgotten.
  void observe(Iterable<VideoStallReading> readings) {
    final now = _clock();
    final next = <String, VideoTileHealth>{};
    final seen = <String>{};
    for (final reading in readings) {
      seen.add(reading.key);
      final track = _tracks.putIfAbsent(reading.key, _Track.new);
      if (reading.paused) {
        track.progressed(now, reading.framesDecoded);
        next[reading.key] = VideoTileHealth.paused;
        continue;
      }
      // A different count either way means progress or a fresh receiver after a resubscribe.
      if (!reading.expectPlaying ||
          reading.framesDecoded == null ||
          reading.framesDecoded != track.frames) {
        track.progressed(now, reading.framesDecoded);
        continue;
      }
      next[reading.key] = _advance(reading.key, track, now);
    }
    _tracks.removeWhere((key, _) => !seen.contains(key));
    next.removeWhere((_, value) => value == VideoTileHealth.playing);
    if (!mapEquals(next, health.value)) health.value = Map.unmodifiable(next);
  }

  VideoTileHealth _advance(String key, _Track track, DateTime now) {
    final due = track.lastStepAt == null
        ? now.difference(track.since) >= stallAfter
        : now.difference(track.lastStepAt!) >= stepGap;
    if (!due) {
      return track.nextStep == 0
          ? VideoTileHealth.playing
          : VideoTileHealth.stalled;
    }
    if (track.nextStep >= VideoStallStep.values.length) {
      return VideoTileHealth.stopped;
    }
    final step = VideoStallStep.values[track.nextStep];
    track.nextStep++;
    track.lastStepAt = now;
    recover(key, step);
    return VideoTileHealth.stalled;
  }

  void dispose() => health.dispose();
}
