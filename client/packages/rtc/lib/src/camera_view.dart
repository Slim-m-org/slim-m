// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders one participant's live camera feed.
///
/// Not exported from the package barrel, for the same reason
/// `screen_share_view.dart` is not: it takes LiveKit types, and the seam
/// this package exists for is that nothing outside it does. The app reaches
/// it through `VoiceSession.cameraViewFor`, which returns it as a plain
/// `Widget`.
///
/// Local and remote alike, unlike an earlier version of `ScreenShareView`
/// that only ever looked at `remoteParticipants`: a local camera preview is
/// exactly the surface that was missing when the owner reported turning a
/// camera on alone in a call and seeing nothing.
///
/// A local front-facing preview mirrors, the same way a real mirror only
/// ever shows the person looking into it; a local back-facing one, and any
/// remote participant's camera regardless of facing, never does. See
/// `mirrorModeFor` in `camera_switching.dart` for the decision itself.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'camera_switching.dart';
import 'first_frame_gate.dart';
import 'track_tile_state.dart';

/// Test-only: how many times each identity's [CameraView] has run `build`,
/// so a rebuild-scoping test can tell a real rebuild from a repaint that
/// looks identical on screen. Same shape as `debugMemberRowBuildCounts`.
@visibleForTesting
final Map<String, int> debugCameraViewBuildCounts = {};

@visibleForTesting
void debugResetCameraViewBuildCounts() => debugCameraViewBuildCounts.clear();

/// One participant's camera video, tracking the room live: a published track
/// routinely arrives a beat after the roster learns a camera is on, the same
/// reason `ScreenShareView` watches room events rather than trusting the
/// state at build time.
class CameraView extends StatefulWidget {
  const CameraView({
    super.key,
    required this.room,
    required this.identity,
    required this.facing,
  });

  final lk.Room room;

  /// Whose camera to render, by server user id. May be the local
  /// participant's own identity.
  final String identity;

  /// This session's own camera facing, only ever meaningful when
  /// [identity] turns out to be the local participant - a flip on this
  /// device says nothing about anyone else's camera.
  final ValueListenable<CameraFacing> facing;

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> with TrackTileState {
  @override
  lk.Room get tileRoom => widget.room;

  @override
  String get tileIdentity => widget.identity;

  @override
  void initState() {
    super.initState();
    // A flip fires no room event at all, so the mirror needs its own listener.
    widget.facing.addListener(_onFacingChanged);
    startTrackTile();
  }

  @override
  void didUpdateWidget(CameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.facing, widget.facing)) {
      oldWidget.facing.removeListener(_onFacingChanged);
      widget.facing.addListener(_onFacingChanged);
    }
    retargetTrackTile(oldWidget.room, oldWidget.identity);
  }

  void _onFacingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.facing.removeListener(_onFacingChanged);
    stopTrackTile();
    super.dispose();
  }

  bool get _isLocal =>
      widget.room.localParticipant?.identity == widget.identity;

  /// Checked as two concretely-typed branches, not one lookup returning the
  /// abstract `Participant`: losing the concrete type there widens
  /// `videoTrackPublications`' element type to a bare `Track`, which no
  /// longer satisfies this method's `VideoTrack?` return.
  @override
  lk.VideoTrack? currentTrack() {
    final local = widget.room.localParticipant;
    if (local != null && local.identity == widget.identity) {
      return _cameraTrackFrom(local.videoTrackPublications);
    }
    for (final p in widget.room.remoteParticipants.values) {
      if (p.identity != widget.identity) continue;
      return _cameraTrackFrom(p.videoTrackPublications);
    }
    return null;
  }

  static lk.VideoTrack? _cameraTrackFrom(
    List<lk.TrackPublication<lk.VideoTrack>> publications,
  ) {
    for (final pub in publications) {
      if (pub.source != lk.TrackSource.camera) continue;
      final track = pub.track;
      if (pub.subscribed && !pub.muted && track != null) return track;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugCameraViewBuildCounts[widget.identity] =
          (debugCameraViewBuildCounts[widget.identity] ?? 0) + 1;
      return true;
    }());
    final track = currentTrack();
    // Unlike a screen share, no placeholder text for a camera not here yet.
    if (track == null) return const SizedBox.shrink();
    final owned = ownedRenderer;
    // The renderer's own initialize() is still pending; same nothing as above.
    if (owned == null) return const SizedBox.shrink();
    return FirstFrameReveal(
      tracker: owned.tracker,
      // No placeholder graphic for a camera either, same as the branch above.
      placeholder: const SizedBox.expand(),
      child: lk.VideoTrackRenderer(
        track,
        fit: lk.VideoViewFit.cover,
        mirrorMode:
            mirrorModeFor(isLocal: _isLocal, facing: widget.facing.value),
        cachedRenderer: owned.renderer,
        autoDisposeRenderer: false,
      ),
    );
  }
}
