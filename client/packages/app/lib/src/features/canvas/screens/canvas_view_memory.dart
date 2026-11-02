// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where each channel's canvas was last panned or zoomed to in the shared view, kept for the session.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Closing the canvas tears its engine down, so this is what outlives it.
///
/// The personal view has its own durable store (decision 0082); this covers the shared view, where a pan or zoom is the viewer's own but nothing else keeps it.
class CanvasViewMemory {
  final Map<String, Camera> _byChannel = {};

  Camera? recall(String channelId) => _byChannel[channelId];

  /// Keeps [camera] for [channelId], or forgets it when null (the viewer is back on the fit, or follows someone).
  void keep(String channelId, Camera? camera) {
    if (camera == null) {
      _byChannel.remove(channelId);
    } else {
      _byChannel[channelId] = camera;
    }
  }
}

final canvasViewMemoryProvider = Provider<CanvasViewMemory>(
  (ref) => CanvasViewMemory(),
);
