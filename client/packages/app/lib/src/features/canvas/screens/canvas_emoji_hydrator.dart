// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Gives each emoji stamp on the board its bitmap (decision 0121): baked once
/// per emoji by the same baker a shared screen uses, and shared by every
/// stamp of that emoji, since a clone of a bitmap costs no pixels.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Distinct emoji kept baked at once; a stamp already painted keeps its own copy.
const canvasEmojiBitmapsKept = 64;

class CanvasEmojiHydrator {
  CanvasEmojiHydrator({
    required this.document,
    required this.bake,
    this.fontsChanged,
    this.dropGlyphBitmaps,
  }) {
    fontsChanged?.addListener(_rebakeVisible);
  }

  /// Notifies when a font finishes loading, after which a glyph baked earlier may have been drawn as a box.
  final Listenable? fontsChanged;

  /// Forgets the glyph bitmaps whoever else caches them holds, so the next bake draws them afresh.
  final VoidCallback? dropGlyphBitmaps;

  final CanvasDocument document;

  /// A bitmap of the emoji under [key] for this hydrator to own, or null when it cannot be had.
  final Future<ui.Image?> Function(String key) bake;

  // Insertion order is the use order, so the first is evicted.
  final _baked = <String, ui.Image>{};
  final _loads = <String, Future<ui.Image?>>{};
  final _pending = <String>{};
  bool _disposed = false;

  /// Bumped by each font load, so a bake begun before it is baked again instead of kept.
  int _generation = 0;

  void hydrate(api.CanvasObject object) {
    final emoji = object.props['emoji'];
    if (_disposed || object.kind != 'emoji' || emoji is! String) return;
    _request(object.id, emoji);
  }

  void hydrateVisible() {
    if (_disposed) return;
    for (final stamp in document.visibleEmojiAwaitingBitmap) {
      _request(stamp.id, stamp.emoji);
    }
  }

  /// Bakes every visible stamp again: the emoji font loads after a reload's first paint, which left boxes baked in.
  void _rebakeVisible() {
    if (_disposed) return;
    dropGlyphBitmaps?.call();
    _generation++;
    _loads.clear();
    for (final image in _baked.values) {
      image.dispose();
    }
    _baked.clear();
    for (final stamp in document.visibleEmojiStamps) {
      _request(stamp.id, stamp.emoji);
    }
  }

  void _request(String id, String key) {
    if (!_pending.add(id)) return;
    _load(id, key);
  }

  Future<void> _load(String id, String key) async {
    final generation = _generation;
    var again = false;
    try {
      final image = await _bitmap(key);
      if (_disposed) return;
      if (generation != _generation) {
        again = true;
      } else if (image == null) {
        document.markImageLoadFailed(id);
      } else {
        document.setImageBitmap(id, image.clone());
      }
    } finally {
      _pending.remove(id);
      if (again) _request(id, key);
    }
  }

  Future<ui.Image?> _bitmap(String key) {
    final held = _baked.remove(key);
    if (held != null) return Future.value(_baked[key] = held);
    final inFlight = _loads[key];
    if (inFlight != null) return inFlight;
    final generation = _generation;
    late final Future<ui.Image?> loading;
    loading = bake(key)
        .then((image) {
          if (image == null) return null;
          if (_disposed || generation != _generation) {
            image.dispose();
            return null;
          }
          _baked[key] = image;
          while (_baked.length > canvasEmojiBitmapsKept) {
            _baked.remove(_baked.keys.first)!.dispose();
          }
          return image;
        })
        .whenComplete(() {
          if (identical(_loads[key], loading)) _loads.remove(key);
        });
    return _loads[key] = loading;
  }

  void dispose() {
    _disposed = true;
    fontsChanged?.removeListener(_rebakeVisible);
    for (final image in _baked.values) {
      image.dispose();
    }
    _baked.clear();
  }
}
