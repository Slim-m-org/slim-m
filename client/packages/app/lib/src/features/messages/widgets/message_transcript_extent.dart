// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why the transcript's scrollbar thumb jittered, and the one number that
/// settles it.
///
/// A `ListView.builder` only lays out what is near the viewport, so it cannot
/// know how tall the whole list is. Flutter's own answer
/// (`SliverMultiBoxAdaptorElement._extrapolateMaxScrollOffset`) averages the
/// heights of exactly the rows laid out right now and multiplies that average
/// by however many rows have not been built:
///
/// ```
/// averageExtent = (trailingScrollOffset - leadingScrollOffset) / reifiedCount
/// return trailingScrollOffset + averageExtent * remainingCount
/// ```
///
/// That is a good estimate for a list of near-identical rows and a poor one
/// here, where a grouped one-line continuation and a headed, wrapped,
/// multi-line message differ several times over. The laid-out window holds
/// only about a screen of rows, so each tall message scrolling into it drags
/// the average up and each one leaving drags it back down, and
/// `maxScrollExtent` - the scrollbar's own denominator - breathes with it. A
/// reader scrolling steadily in one direction sees the thumb slide backwards
/// every other frame, which is the reported "jumps around a lot and doesn't
/// move cleanly".
///
/// [TranscriptExtentEstimator] answers the same question from a far wider
/// sample. `trailingScrollOffset` is the measured height of *every* row from
/// the newest down to the last one built, so dividing it by that many rows is
/// a mean over the whole distance already read rather than over the screenful
/// on show - and the deeper the reader goes, the less any one row can move it.
/// [_averageSettling] then damps what remains.
///
/// Measured against a 300-message transcript of deliberately mixed row heights,
/// stepped 60px at a time (`message_transcript_extent_test.dart` is the same
/// fixture). Flutter's own estimate moved the thumb backwards, against the
/// direction of scrolling, on 175 of 401 frames, by up to 2.8% of the track,
/// with the extent itself swinging 21%; scrolling up and back down again left
/// it 19% from where it started. This gives 28 frames, 0.4%, 5%, and 3%.
///
/// What this deliberately does not do is make the scrollbar represent the
/// whole conversation. The extent is still the loaded window's, and it still
/// grows by a page whenever [ChannelHistoryController.loadOlder] answers; see
/// `channel_history.dart`'s own library doc for why a full-history proportion
/// would need a total the client has no way to ask for. That page-sized step
/// is one discrete move, at the top of the list where the reader already is,
/// and it is a different thing from the per-frame sawtooth this removes.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The transcript's running answer to "how tall is the whole loaded list".
///
/// Held by `_MessageTranscriptState` rather than by the delegate, because
/// `ListView` builds a fresh [SliverChildDelegate] on every rebuild and state
/// living there would be discarded on each one - which is every arriving
/// message, so in a busy channel it would be discarded constantly and the
/// jitter would come straight back.
///
/// Every reading is taken from the geometry of the layout being asked about,
/// never from one remembered out of an earlier one. An earlier draft anchored
/// on the deepest row ever laid out, which is steadier still and was wrong:
/// the first layout after a channel switch reports the *previous* channel's
/// offsets, and an anchor that only ever moves deeper locked that reading in
/// until the reader scrolled past it in the new channel, leaving a short
/// conversation claiming to be twice its real length. Steadiness is worth
/// having only while the number is also true.
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
