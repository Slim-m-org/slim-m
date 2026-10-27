// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The short "1080p 60" readout for a video the viewer is receiving.
library;

import 'call_stats.dart';

/// The sample key of the remote [source] track published by [identity].
String receivedStatsKey(String identity, CallStatsSource source) =>
    'in/$identity/${source.name}';

/// What is arriving in [sample], or null before any frame has been decoded.
///
/// With simulcast the receiver reports the one layer the SFU forwards, so the
/// label follows layer switches on the next sample.
String? streamQualityLabel(VideoStatsSample? sample) {
  final streams = [
    for (final s in sample?.streams ?? const <VideoStreamStats>[])
      if ((s.height ?? 0) > 0) s,
  ];
  if (streams.isEmpty) return null;
  final best = streams.reduce(
    (a, b) => (b.height ?? 0) > (a.height ?? 0) ? b : a,
  );
  final fps = best.fps;
  return fps == null || fps < 1
      ? '${best.height}p'
      : '${best.height}p ${fps.round()}';
}
