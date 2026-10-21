// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Full screen on a call tile changes the view, never the tile (decision 0081): the camera fits the tile's world rect while it is focused and goes back afterwards.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_presence_frame.dart';
import 'canvas_presence_geometry.dart';

/// How long a feed may be gone before the focus is dropped; a voice reconnect
/// empties the roster for a moment and brings the same people back.
const Duration focusedTileGrace = Duration(seconds: 4);

/// Paints nothing. Holds the camera fitted to [tileKey]'s rect for as long as it is mounted, then puts back the camera it found.
/// The camera is a local view, so nothing here reaches other viewers, and the shared or personal view stays as it was.
class CanvasFocusedFit extends StatefulWidget {
  const CanvasFocusedFit({
    super.key,
    required this.document,
    required this.tileKey,
    required this.participants,
    required this.overrides,
    required this.resolver,
    required this.hideSelfCamera,
    required this.onLost,
  });

  final CanvasDocument document;
  final String tileKey;
  final List<VoiceParticipant> participants;
  final CanvasPresenceTileOverrides overrides;
  final CanvasPresenceFrameResolver resolver;
  final bool hideSelfCamera;

  /// Called when the feed ended, or its person stayed gone past [focusedTileGrace], so the focus can be dropped.
  final VoidCallback onLost;

  @override
  State<CanvasFocusedFit> createState() => _CanvasFocusedFitState();
}

class _CanvasFocusedFitState extends State<CanvasFocusedFit> {
  late final Camera _before;
  late final bool _beforeFitted;
  Timer? _lostTimer;
  bool _refitScheduled = false;
  ({Rect rect, Size viewport, double inset})? _fitted;

  @override
  void initState() {
    super.initState();
    _before = widget.document.camera;
    _beforeFitted = widget.document.isFitted;
    widget.document.addListener(_scheduleRefit);
    widget.overrides.addListener(_scheduleRefit);
    _scheduleRefit();
  }

  @override
  void didUpdateWidget(covariant CanvasFocusedFit oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleRefit();
  }

  @override
  void dispose() {
    widget.document.removeListener(_scheduleRefit);
    widget.overrides.removeListener(_scheduleRefit);
    _lostTimer?.cancel();
    _restoreAfterLayout(widget.document);
    super.dispose();
  }

  // After the frame, so the chrome coming back has already resized the viewport the camera is held to.
  void _restoreAfterLayout(CanvasDocument document) {
    final before = _before;
    final fitted = _beforeFitted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (document.isDisposed) return;
      fitted ? document.fitBoard() : document.setCamera(before);
    });
  }

  void _scheduleRefit() {
    if (_refitScheduled) return;
    _refitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refitScheduled = false;
      if (mounted) _refit();
    });
  }

  Rect? _tileRect() => widget.resolver
      .resolve(
        participants: widget.participants,
        document: widget.document,
        overrides: widget.overrides,
        layout: const CanvasPresenceLayout(),
        hideSelfCamera: widget.hideSelfCamera,
      )
      .onCanvas[widget.tileKey];

  // Only a change of the tile or the window refits, so a pan or zoom the viewer chose in full screen is left alone.
  void _refit() {
    final document = widget.document;
    final rect = _tileRect();
    if (rect == null || document.viewport.isEmpty) return;
    final next = (
      rect: rect,
      viewport: document.viewport,
      inset: document.bottomInset,
    );
    if (next == _fitted) return;
    _fitted = next;
    document.showWorldRect(rect);
  }

  // A roster that lost the person may be a reconnect; one that still lists them without the feed means it ended.
  void _syncLostTimer({required bool live, required bool present}) {
    if (live) {
      _lostTimer?.cancel();
      _lostTimer = null;
      return;
    }
    if (present) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onLost());
      return;
    }
    _lostTimer ??= Timer(focusedTileGrace, widget.onLost);
  }

  @override
  Widget build(BuildContext context) {
    final tileKey = widget.tileKey;
    final isScreen = presenceTileKind(tileKey) == screenTrackKind;
    final identity = presenceTileIdentity(tileKey);
    final participant = widget.participants
        .where((p) => p.identity == identity)
        .firstOrNull;
    final live =
        participant != null &&
        (isScreen ? participant.isScreenSharing : participant.isCameraOn);
    _syncLostTimer(live: live, present: participant != null);
    return const SizedBox.shrink();
  }
}
