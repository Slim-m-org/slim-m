// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop player: a webview the runner keeps out of sight, whose frames
/// Flutter draws as a texture wherever the video belongs, and which takes
/// the pointer Flutter forwards to it.
library;

import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable;

import 'embedded_video_player.dart';

enum VideoPointerKind { enter, move, down, up, leave }

abstract interface class DesktopVideoPlayer implements EmbeddedVideoPlayer {
  /// The Flutter texture showing the player, null until its view exists.
  ValueListenable<int?> get texture;

  /// Sizes the page to the box showing it: [size] in logical pixels, drawn
  /// at [pixelRatio] physical pixels to each.
  Future<void> resize(Size size, double pixelRatio);

  /// Forwards one primary-button pointer event at [position] in the page.
  Future<void> pointer(VideoPointerKind kind, Offset position);

  /// Takes the page out of fullscreen, when the app left it first.
  Future<void> exitFullscreen();
}
