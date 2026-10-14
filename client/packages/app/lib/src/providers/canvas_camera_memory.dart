// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where each channel's Voice Canvas camera was left, so reopening a canvas,
/// or relaunching, comes back to the same view instead of the world origin.
/// Device-local, like the other `slimm.canvas.*` preferences.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'providers.dart';

const canvasCamerasKey = 'slimm.canvas.cameras.v1';

/// The most channels remembered; the oldest is dropped past this.
const _maxRemembered = 64;

class CanvasCameraMemory {
  CanvasCameraMemory(this._ref) {
    ready = _load();
  }

  final Ref _ref;
  final Map<String, Camera> _cameras = {};
  late final Future<void> ready;

  Camera? cameraFor(String channelId) => _cameras[channelId];

  Future<void> _load() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final raw = prefs.getString(canvasCamerasKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final values = (entry.value as List).cast<num>();
        _cameras.putIfAbsent(
          entry.key,
          () => Camera(
            x: values[0].toDouble(),
            y: values[1].toDouble(),
            zoom: values[2].toDouble(),
          ),
        );
      }
    } catch (_) {
      // An unreadable store just means every canvas opens at the origin, as before.
    }
  }

  /// Records [camera] for [channelId] and writes the set back.
  Future<void> remember(String channelId, Camera camera) async {
    _cameras.remove(channelId);
    _cameras[channelId] = camera;
    while (_cameras.length > _maxRemembered) {
      _cameras.remove(_cameras.keys.first);
    }
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.setString(
        canvasCamerasKey,
        jsonEncode({
          for (final e in _cameras.entries)
            e.key: [e.value.x, e.value.y, e.value.zoom],
        }),
      );
    } catch (_) {
      // Best effort: this session still remembers it in memory.
    }
  }
}

/// Not autoDispose: the canvas engine is rebuilt on every open, and this has
/// to outlive it.
final canvasCameraMemoryProvider = Provider<CanvasCameraMemory>(
  CanvasCameraMemory.new,
);
