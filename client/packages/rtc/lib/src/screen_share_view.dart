// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders one participant's shared screen.
///
/// Not exported from the package barrel on purpose: it takes LiveKit types,
/// and the seam this package exists for is that nothing outside it does. The
/// app reaches it through `VoiceSession.screenShareViewFor`, which returns it
/// as a plain [Widget].
///
/// Why this exists at all: publishing a share and *seeing* one are separate
/// halves, and only the first was built. A peer's share reached the client as
/// a subscribed track (the e2e run proves that at the SFU) and then nothing
/// anywhere rendered it - the viewer saw a glyph on a roster row and no
/// screen. This is the missing half.
///
/// [_participant] checks the local participant too, not only remote ones: an
/// earlier version only ever found a remote share, so a lone caller who
/// started sharing saw the same nothing this whole widget exists to fix.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'first_frame_gate.dart';
import 'track_tile_state.dart';

/// Test-only build counter, keyed by identity; see the twin in
/// `camera_view.dart` for why a rebuild-scoping test needs it.
@visibleForTesting
final Map<String, int> debugScreenShareViewBuildCounts = {};

@visibleForTesting
void debugResetScreenShareViewBuildCounts() =>
    debugScreenShareViewBuildCounts.clear();

/// One participant's screen share video, tracking the room live.
///
/// Listens to the room's own event stream rather than trusting the state at
/// build time, because the track routinely arrives *after* the roster learns
/// the participant is sharing: subscription lags the boolean by a beat, and a
/// widget built in that beat would show the placeholder forever.
class ScreenShareView extends StatefulWidget {
  const ScreenShareView({
    super.key,
    required this.room,
    required this.identity,
  });

  final lk.Room room;

  /// Whose share to render, by server user id.
  final String identity;

  @override
  State<ScreenShareView> createState() => _ScreenShareViewState();
}

class _ScreenShareViewState extends State<ScreenShareView> with TrackTileState {
  @override
  lk.Room get tileRoom => widget.room;

  @override
  String get tileIdentity => widget.identity;

  @override
  void initState() {
    super.initState();
    startTrackTile();
  }

  @override
  void didUpdateWidget(ScreenShareView oldWidget) {
    super.didUpdateWidget(oldWidget);
    retargetTrackTile(oldWidget.room, oldWidget.identity);
  }

  @override
  void dispose() {
    stopTrackTile();
    super.dispose();
  }

  /// Checked as two concretely-typed branches, not one lookup returning the
  /// abstract `Participant`: see `camera_view.dart`'s own copy of this note.
  @override
  lk.VideoTrack? currentTrack() {
    final local = widget.room.localParticipant;
    if (local != null && local.identity == widget.identity) {
      return _shareTrackFrom(local.videoTrackPublications);
    }
    for (final p in widget.room.remoteParticipants.values) {
      if (p.identity != widget.identity) continue;
      return _shareTrackFrom(p.videoTrackPublications);
    }
    return null;
  }

  static lk.VideoTrack? _shareTrackFrom(
    List<lk.TrackPublication<lk.VideoTrack>> publications,
  ) {
    for (final pub in publications) {
      if (pub.source != lk.TrackSource.screenShareVideo) continue;
      final track = pub.track;
      if (pub.subscribed && !pub.muted && track != null) return track;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugScreenShareViewBuildCounts[widget.identity] =
          (debugScreenShareViewBuildCounts[widget.identity] ?? 0) + 1;
      return true;
    }());
    final track = currentTrack();
    // Honest about the beat between "sharing" and the track arriving.
    if (track == null) return _placeholder;
    // And the further beat between the track arriving and a real frame.
    final owned = ownedRenderer;
    if (owned == null) return _placeholder;
    return FirstFrameReveal(
      tracker: owned.tracker,
      placeholder: _placeholder,
      child: OwnedRendererView(
        owned: owned,
        builder: (renderer) => lk.VideoTrackRenderer(
          track,
          fit: lk.VideoViewFit.contain,
          cachedRenderer: renderer,
          autoDisposeRenderer: false,
        ),
      ),
    );
  }

  static const _placeholder = ScreenSharePlaceholder();
}

/// Three staggered pulsing dots, in place of a "waiting" sentence that read
/// as stalled rather than loading. Not `AppTypingDots`: this package takes
/// no dependency on `design_system` (the two sit side by side in the
/// layering, `docs/BRIEF.md`'s code map), so the same pulse is reproduced
/// locally with the placeholder's own plain color rather than a token.
/// Public, with its state, only so a widget test can drive the animation and
/// the reduced-motion branch directly - `ScreenShareView` never exposes it.
@visibleForTesting
class ScreenSharePlaceholder extends StatefulWidget {
  const ScreenSharePlaceholder();

  @override
  State<ScreenSharePlaceholder> createState() => ScreenSharePlaceholderState();
}

class ScreenSharePlaceholderState extends State<ScreenSharePlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool get _reduced =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduced) {
      _t.stop();
      _t.value = 0;
    } else if (!_t.isAnimating) {
      _t.repeat();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// Each dot's pulse trails the one before it by a fifth of the loop, so the
  /// three read as a wave rather than blinking in unison - see the identical
  /// shape in `design_system`'s own `AppTypingDots`.
  double _opacityFor(int index, double t) {
    if (_reduced) return 1;
    final phase = (t - index * 0.2) * 2 * math.pi;
    return 0.35 + 0.5 * (0.5 + 0.5 * math.sin(phase));
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Semantics(
          label: 'Loading screen share',
          child: AnimatedBuilder(
            animation: _t,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                    child: Opacity(
                      opacity: _opacityFor(i, _t.value),
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0xFF9AA4AD),
                          shape: BoxShape.circle,
                        ),
                        child: SizedBox.square(dimension: 6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}
