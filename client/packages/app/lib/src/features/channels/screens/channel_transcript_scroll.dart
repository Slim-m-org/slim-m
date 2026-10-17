// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the transcript's scroll sits, and the two things that follow from
/// it: the "jump to latest" affordance's visibility and when a viewed
/// message is marked read. The affordance shows only once the reader has
/// left the tail of the conversation and is heading back toward it, not
/// merely for having left it.
///
/// Split out of `channel_screen.dart`, which had no line budget left to grow
/// into. It owns the [ScrollController] itself, not just state derived from
/// it, because both have to survive `ChannelScreen`'s own outlives-a-channel-
/// switch lifetime (see `channel_read_marker.dart`'s doc comment) and reset
/// together: a controller reset with nothing telling the arrow to hide, or
/// an arrow hidden while the controller still sits mid-history, are each
/// half of the same bug on their own.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

class TranscriptScrollTracker {
  TranscriptScrollTracker({required this.markRead}) {
    controller.addListener(_onScrollChanged);
  }

  /// Called with the channel's newest delivered seq, last-read marker, and
  /// hand-mark state once the transcript is confirmed at the latest message.
  final void Function(int seq, int lastReadSeq, bool manuallyUnread) markRead;

  final ScrollController controller = ScrollController();

  /// A [ValueNotifier] rather than a `setState`-tracked field on purpose:
  /// rebuilding the whole screen on every scroll frame that crosses a
  /// threshold would make the read marker's own correctness depend on that
  /// rebuild reaching the transcript's gate, which [_onScrollChanged] is not
  /// allowed to lean on.
  final ValueNotifier<bool> scrolledAway = ValueNotifier(false);

  bool _disposed = false;
  int _latestSeq = 0;
  int _lastReadSeq = 0;
  bool _manuallyUnread = false;

  /// The offset last seen while genuinely away from the latest message; null
  /// while at rest, so a fresh departure has no direction to compare against
  /// yet. See [_onScrollChanged] for what this drives.
  double? _lastAwayPixels;

  /// How close to [ScrollPosition.minScrollExtent] still counts as "at the
  /// latest message" for read-marking, covering overscroll bounce and float
  /// rounding from [scrollToLatest]'s own animation landing. Deliberately
  /// tight and unrelated to [_scrolledAwayFraction]: marking read is about
  /// truly being back at the bottom, not about the arrow's own, coarser,
  /// "did the reader mean to leave" question below.
  static const double _atLatestSlop = 4;

  /// How much of the viewport must be scrolled past the newest message
  /// before the jump-to-latest control is even a candidate to show. Screen-
  /// relative rather than a fixed pixel count, since the same absolute
  /// distance is a full screen on a phone and a sliver of a wide desktop
  /// window: 30% of whatever is currently visible is "no longer looking at
  /// the tail of the conversation" on either.
  static const double _scrolledAwayFraction = 0.3;

  /// Floor under [_scrolledAwayFraction], roughly two grouped message rows,
  /// so a short viewport (a compact split-pane column) still asks for a real
  /// scroll rather than a few dozen pixels of one.
  static const double _scrolledAwayFloor = 96;

  /// How far a sample has to move before it counts as real motion rather
  /// than scroll-delta noise, for the direction check in [_onScrollChanged].
  static const double _directionSlop = 2;

  void dispose() {
    _disposed = true;
    controller
      ..removeListener(_onScrollChanged)
      ..dispose();
    scrolledAway.dispose();
  }

  /// True while the viewport shows the newest message: no scrollable has
  /// attached yet (nothing has laid out to have scrolled away from, and the
  /// list starts bottom-anchored so a first paint always begins there), or
  /// the offset already sits within [_atLatestSlop] of
  /// [ScrollPosition.minScrollExtent].
  bool get atLatest {
    if (!controller.hasClients) return true;
    final position = controller.position;
    return position.pixels <= position.minScrollExtent + _atLatestSlop;
  }

  bool get _scrolledAwayEnough {
    if (!controller.hasClients) return false;
    final position = controller.position;
    final threshold = math.max(
      position.viewportDimension * _scrolledAwayFraction,
      _scrolledAwayFloor,
    );
    return position.pixels - position.minScrollExtent > threshold;
  }

  /// Scrolling never rebuilds the transcript's `StreamBuilder`, so returning
  /// to the latest message needs its own trigger to re-mark read; this is
  /// it, on its own, independent of whether the arrow happens to repaint.
  ///
  /// The arrow itself asks for more than distance: leaving the tail is not a
  /// reason to show a way back on its own, only heading toward the latest
  /// message while still away from it is - so a fresh departure only arms a
  /// baseline, and the arrow reveals itself on the first sample after that
  /// moves back toward [ScrollPosition.minScrollExtent].
  void _onScrollChanged() {
    final wasAtLatest = atLatest;
    if (!_scrolledAwayEnough) {
      scrolledAway.value = false;
      _lastAwayPixels = null;
    } else {
      final pixels = controller.position.pixels;
      final last = _lastAwayPixels;
      if (last != null && pixels < last - _directionSlop) {
        scrolledAway.value = true;
      } else if (last != null && pixels > last + _directionSlop) {
        scrolledAway.value = false;
      }
      _lastAwayPixels = pixels;
    }
    if (wasAtLatest) markRead(_latestSeq, _lastReadSeq, _manuallyUnread);
  }

  /// Called on every transcript rebuild, so a scroll event arriving between
  /// rebuilds always marks read against the channel actually on screen.
  void updateKnownSeqs({
    required int latestSeq,
    required int lastReadSeq,
    required bool manuallyUnread,
  }) {
    _latestSeq = latestSeq;
    _lastReadSeq = lastReadSeq;
    _manuallyUnread = manuallyUnread;
  }

  /// A new channel always opens at its own newest message: without this, a
  /// channel opened right after scrolling into a different one's history
  /// opened already scrolled away from its own newest message too, since the
  /// controller and [scrolledAway] both outlive the switch.
  ///
  /// The jump itself is deferred a frame so it lands after the transcript
  /// has rebuilt for the new channel: doing it inline would fire
  /// [_onScrollChanged] against [_latestSeq] and [_lastReadSeq], which still
  /// hold the previous channel's values at the point a channel switch is
  /// noticed.
  void resetForChannelSwitch() {
    scrolledAway.value = false;
    _lastAwayPixels = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !controller.hasClients) return;
      controller.jumpTo(controller.position.minScrollExtent);
    });
  }

  /// The list is reversed, so the latest message sits at offset zero.
  void scrollToLatest({required Duration duration}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !controller.hasClients) return;
      controller.animateTo(
        controller.position.minScrollExtent,
        duration: duration,
        curve: AppMotion.entrance,
      );
    });
  }
}
