// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the canvas tile that fills the pane at full video sharpness, whatever the receive quality.
library;

import 'dart:ui' show VoidCallback;

/// Follows the focused tile and holds exactly one enlarged-video key for it, released when focus moves or clears.
class CanvasFocusVideoHold {
  /// [hold] is the voice session's `holdEnlargedVideo`; the result releases that key.
  CanvasFocusVideoHold(this._hold);

  final VoidCallback Function(String tileKey) _hold;
  String? _key;
  VoidCallback? _release;

  /// The tile key held now, or null.
  String? get heldKey => _key;

  /// Holds [tileKey], swapping any earlier hold; null releases.
  void follow(String? tileKey) {
    if (tileKey == _key) return;
    _release?.call();
    _key = tileKey;
    _release = tileKey == null ? null : _hold(tileKey);
  }

  void release() => follow(null);
}
