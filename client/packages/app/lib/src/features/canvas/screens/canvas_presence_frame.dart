// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One resolution of the call tiles, shared by `CanvasPresenceLayer` (front)
/// and `CanvasPresenceBackdrop` (sent to back).
///
/// Both widgets used to run `presenceTileKeys` -> `presenceOnCanvasRects` ->
/// their own hysteretic `CanvasPresenceVisibility`, and only agreed while both
/// kept the same early returns. Resolving through one instance makes that
/// agreement structural.
library;

import 'dart:ui';

import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_presence_geometry.dart';

/// What one build of the tiles needs, resolved once.
class CanvasPresenceFrame {
  const CanvasPresenceFrame({
    required this.keys,
    required this.byIdentity,
    required this.onCanvas,
    required this.visibleIds,
  });

  static const empty = CanvasPresenceFrame(
    keys: <String>{},
    byIdentity: <String, VoiceParticipant>{},
    onCanvas: <String, Rect>{},
    visibleIds: <String>{},
  );

  final Set<String> keys;
  final Map<String, VoiceParticipant> byIdentity;

  /// Every tile's world rect, excluding hidden ones.
  final Map<String, Rect> onCanvas;

  /// The subset of [onCanvas] worth mounting, with spatial hysteresis.
  final Set<String> visibleIds;
}

class CanvasPresenceFrameResolver {
  final CanvasPresenceVisibility _visibility = CanvasPresenceVisibility();

  /// Safe to call more than once per frame with the same input: the
  /// visibility test is idempotent for an unchanged viewport and rects.
  CanvasPresenceFrame resolve({
    required List<VoiceParticipant> participants,
    required CanvasDocument document,
    required CanvasPresenceTileOverrides overrides,
    required CanvasPresenceLayout layout,
    required bool hideSelfCamera,
  }) {
    final keys = presenceTileKeys(participants);
    if (keys.isEmpty) return CanvasPresenceFrame.empty;
    final byIdentity = {for (final p in participants) p.identity: p};
    // World units when the board is fixed, so every viewer gets the same untouched layout.
    final frame = document.board?.size ?? document.viewport;
    final onCanvas = presenceOnCanvasRects(
      keys: keys,
      layout: layout.withMaxRowWidth(frame.width),
      overrides: overrides,
      byIdentity: byIdentity,
      hideSelfCamera: hideSelfCamera,
      viewport: frame,
    );
    // Ahead of the visibility update, so an empty roster never disturbs the mounted set.
    final visibleIds = onCanvas.isEmpty
        ? const <String>{}
        : _visibility.update(document.worldView, onCanvas);
    return CanvasPresenceFrame(
      keys: keys,
      byIdentity: byIdentity,
      onCanvas: onCanvas,
      visibleIds: visibleIds,
    );
  }
}

/// Tells a document notification that moved the view from one that only
/// changed content, so tiles do not rebuild for every stroke or remote preview.
class CanvasViewChangeGate {
  Camera? _camera;
  Size? _viewport;
  Rect? _board;

  bool changed(CanvasDocument document) {
    final camera = document.camera;
    final viewport = document.viewport;
    final board = document.board;
    if (camera == _camera && viewport == _viewport && board == _board) {
      return false;
    }
    _camera = camera;
    _viewport = viewport;
    _board = board;
    return true;
  }
}
