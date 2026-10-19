// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Remembers where a channel's canvas camera was left, and puts it back.
library;

import 'dart:async';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../providers/canvas_camera_memory.dart';

class CanvasCameraKeeper {
  CanvasCameraKeeper(this._memory, this._channelId, this._document);

  final CanvasCameraMemory _memory;
  final String _channelId;
  final CanvasDocument _document;
  Timer? _save;

  /// Whether a camera was ever saved for this channel.
  bool get hasSaved => _memory.cameraFor(_channelId) != null;

  /// Puts the camera back where it was left, unless it has already moved
  /// since opening.
  Future<void> restore({required bool Function() mounted}) async {
    await _memory.ready;
    final saved = _memory.cameraFor(_channelId);
    if (!mounted() || saved == null || _document.camera != const Camera()) {
      return;
    }
    _document.setCamera(saved);
  }

  /// Saves the camera once it has been still for half a second.
  void remember() {
    _save?.cancel();
    _save = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_memory.remember(_channelId, _document.camera)),
    );
  }

  /// Saves a pending camera now rather than losing it with the canvas.
  void flush() {
    if (!(_save?.isActive ?? false)) return;
    _save!.cancel();
    unawaited(_memory.remember(_channelId, _document.camera));
  }
}
