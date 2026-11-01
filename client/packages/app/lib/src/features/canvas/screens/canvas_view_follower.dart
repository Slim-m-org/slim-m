// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this device's camera does when it follows someone or is summoned, and what its own movement tells the relay.
library;

import 'dart:async';
import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_view_relay.dart';

class CanvasViewFollower {
  CanvasViewFollower({
    required this.document,
    required this.viewMode,
    required this.relay,
    required this.existingRelay,
    required this.glide,
    this.holdsFitCamera,
  });

  final CanvasDocument document;
  final CanvasViewMode viewMode;

  /// The relay, created on first use.
  final CanvasViewRelay Function() relay;

  /// The relay if one exists yet; following nobody needs none.
  final CanvasViewRelay? Function() existingRelay;

  /// How long the camera eases to a followed view; zero under reduce motion.
  final Duration Function() glide;

  /// True while a followed full screen tile owns the camera, so its fit is not the follower panning away.
  final bool Function()? holdsFitCamera;

  Camera? _viewCamera;
  bool _showingView = false;
  Timer? _ease;
  Size _viewport = Size.zero;

  /// Following or being summoned shows the shared board and keeps the personal layout for the way back.
  /// A followed view arrives about ten times a second, so the camera eases to each instead of jumping.
  void showView(Rect view) {
    _showingView = true;
    viewMode.showShared();
    final board = document.board;
    final from = document.camera;
    final target = board == null
        ? null
        : cameraForBoardView(view, board, document.viewport);
    final duration = glide();
    _ease?.cancel();
    if (target == null ||
        target == from ||
        duration <= Duration.zero ||
        document.viewport.isEmpty) {
      document.showBoardView(view);
      _settle();
      return;
    }
    _showingView = false;
    _viewCamera = document.camera;
    const frame = Duration(milliseconds: 16);
    // The tick counts elapsed periods even when a callback runs late, so the ease keeps time without a wall clock.
    _ease = Timer.periodic(frame, (timer) {
      final t = (timer.tick * frame.inMicroseconds / duration.inMicroseconds)
          .clamp(0.0, 1.0);
      final eased = 1 - (1 - t) * (1 - t);
      _showingView = true;
      document.setCamera(
        Camera(
          x: from.x + (target.x - from.x) * eased,
          y: from.y + (target.y - from.y) * eased,
          zoom: from.zoom + (target.zoom - from.zoom) * eased,
        ),
      );
      _settle();
      if (t >= 1) timer.cancel();
    });
  }

  void _settle() {
    _showingView = false;
    _viewCamera = document.camera;
    _viewport = document.viewport;
  }

  // Choosing the personal view is leaving the followed person's view, even when the camera stays put.
  void onViewModeChanged() {
    if (viewMode.personal) existingRelay()?.stopFollowing();
  }

  // Following ends on the follower's own pan or zoom, but a window resize only refits.
  void onViewMoved() {
    final visible = document.visibleBoard;
    if (visible == null || document.viewport.isEmpty || _showingView) return;
    // A personal camera is nobody else's to follow or be summoned to (decision 0082).
    if (!viewMode.personal) relay().reportLocal(visible);
    final followed = existingRelay()?.following.value;
    final resized = _viewport != document.viewport;
    _viewport = document.viewport;
    if (followed == null) return;
    if (resized) {
      showView(relay().viewOf(followed));
    } else if (document.camera != _viewCamera) {
      if (holdsFitCamera?.call() ?? false) {
        _viewCamera = document.camera;
        return;
      }
      _ease?.cancel();
      relay().stopFollowing();
    }
  }

  void dispose() => _ease?.cancel();
}
