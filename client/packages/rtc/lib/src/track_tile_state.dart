// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The renderer lifecycle `CameraView` and `ScreenShareView` share: follow one
/// participant's track in one room, and hold a fresh [OwnedVideoRenderer] per
/// track. A fix to either belongs here once.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'first_frame_gate.dart';
import 'track_event_filter.dart';

mixin TrackTileState<T extends StatefulWidget> on State<T> {
  lk.CancelListenFunc? _cancel;
  lk.VideoTrack? _renderedTrack;

  /// The renderer for the track now showing, or null before its initialize()
  /// completes.
  OwnedVideoRenderer? ownedRenderer;

  lk.Room get tileRoom;
  String get tileIdentity;

  /// The live track this tile should render now, or null.
  lk.VideoTrack? currentTrack();

  /// Call from `initState`.
  void startTrackTile() {
    _subscribe();
    _syncRenderer();
  }

  /// Call from `didUpdateWidget`, passing the previous room and identity.
  void retargetTrackTile(lk.Room oldRoom, String oldIdentity) {
    if (!identical(oldRoom, tileRoom)) {
      _cancel?.call();
      _subscribe();
    }
    if (!identical(oldRoom, tileRoom) || oldIdentity != tileIdentity) {
      _syncRenderer();
    }
  }

  /// Call from `dispose`.
  void stopTrackTile() {
    _cancel?.call();
    final owned = ownedRenderer;
    ownedRenderer = null;
    if (owned != null) unawaited(owned.dispose());
  }

  void _subscribe() {
    // Only this participant's own track changes can alter what we render; every other room event is noise.
    _cancel = tileRoom.events.listen((event) {
      if (mounted && trackEventAffectsIdentity(event, tileIdentity)) {
        _syncRenderer();
        setState(() {});
      }
    });
  }

  /// Swaps in a fresh [OwnedVideoRenderer] whenever the track this tile
  /// renders changes, so a track that appears after one has gone away gets its
  /// own first-frame warm-up rather than inheriting a stale renderer's
  /// already-latched `FirstFrameTracker`.
  void _syncRenderer() {
    final track = currentTrack();
    if (identical(track, _renderedTrack)) return;
    _renderedTrack = track;
    final stale = ownedRenderer;
    ownedRenderer = null;
    if (stale != null) unawaited(stale.dispose());
    if (track != null) unawaited(_attachRenderer(track));
  }

  Future<void> _attachRenderer(lk.VideoTrack track) async {
    final owned = OwnedVideoRenderer();
    await owned.initialize();
    if (!mounted || !identical(track, _renderedTrack)) {
      unawaited(owned.dispose());
      return;
    }
    setState(() => ownedRenderer = owned);
  }
}
