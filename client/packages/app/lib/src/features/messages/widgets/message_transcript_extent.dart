// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A steadier estimate of the transcript's total height, so the scrollbar
/// thumb stops sliding backwards while the reader scrolls one way.
///
/// Flutter extrapolates from the rows laid out right now, which swings with
/// every tall message entering or leaving the screen. This averages over
/// every row already measured, then damps the change; on the mixed-height
/// fixture in `message_transcript_extent_test.dart` backwards frames fell
/// from 175 of 401 to 28. It still covers only the loaded window, which
/// grows a page at a time.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The transcript's running height estimate, held by the transcript's state
/// because the list rebuilds its delegate on every message. Each reading
/// comes from the layout being asked about, so a channel switch never
/// inherits the last channel's offsets.
class TranscriptExtentEstimator {
  /// How far each new reading moves the settled row-height average.
  ///
  /// The average is multiplied by every row not yet built, so on a long
  /// transcript a small wobble in it is a large wobble in the answer, which
  /// is the whole reason Flutter's own per-frame average is unusable here. A
  /// tenth damps one unusually tall row at the boundary to a tenth of its
  /// effect while still settling within a few dozen layouts, well under a
  /// second of scrolling.
  static const double _averageSettling = 0.1;

  /// The settled mean row height, or null before the first reading.
  double? _average;

  /// Readings taken since the last [reset], which is what makes the settling
  /// above start fast and slow down.
  ///
  /// A tenth is the right pace for damping one odd row out of a conversation
  /// already being read, and much too slow for the first moments in a new
  /// one: the very first layout after a channel switch still reports the
  /// previous channel's offsets, so seeding on it and then creeping away at a
  /// tenth a frame leaves the thumb visibly wrong for the best part of a
  /// second. Weighting each of the first readings as a plain running mean
  /// instead washes that out within a handful of frames and then hands over
  /// to the steady rate, which is the one that matters for the rest of the
  /// session.
  int _readings = 0;

  /// Forgets what has settled, for when the rows it was measured from stop
  /// being the rows on screen - a channel switch, where the next conversation
  /// may be built of quite differently sized messages.
  void reset() {
    _average = null;
    _readings = 0;
  }

  /// The estimate, in the shape [SliverChildDelegate.estimateMaxScrollOffset]
  /// asks for. Null hands the question back to Flutter's own extrapolation,
  /// which is the right answer before anything has been measured.
  double? estimate({
    required int childCount,
    required int lastIndex,
    required double trailingScrollOffset,
  }) {
    final remaining = childCount - 1 - lastIndex;
    // Every row is built, so the total is measured rather than estimated; Flutter's own extrapolation short-circuits here too.
    if (remaining <= 0) return trailingScrollOffset;
    if (trailingScrollOffset <= 0) return null;
    final sample = trailingScrollOffset / (lastIndex + 1);
    final settled = _average;
    final settling = math.max(1 / (_readings + 1), _averageSettling);
    final average = settled == null
        ? sample
        : settled + (sample - settled) * settling;
    _average = average;
    _readings++;
    return trailingScrollOffset + average * remaining;
  }
}

/// A [SliverChildBuilderDelegate] that answers the extent question from
/// [estimator] instead of from the rows currently on screen.
///
/// Everything else is the delegate `ListView.builder` would have built - the
/// same automatic keep-alives, repaint boundaries and semantic indexes - so
/// swapping `ListView.builder` for `ListView.custom` changes only the one
/// method below.
class TranscriptChildDelegate extends SliverChildBuilderDelegate {
  TranscriptChildDelegate(
    super.builder, {
    required int super.childCount,
    required this.estimator,
  });

  final TranscriptExtentEstimator estimator;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => estimator.estimate(
    childCount: childCount!,
    lastIndex: lastIndex,
    trailingScrollOffset: trailingScrollOffset,
  );
}
