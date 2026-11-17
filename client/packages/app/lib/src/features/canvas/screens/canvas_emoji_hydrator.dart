// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Gives each emoji stamp on the board its bitmap (decision 0121): baked once
/// per emoji by the same baker a shared screen uses, and shared by every
/// stamp of that emoji, since a clone of a bitmap costs no pixels.
library;

import 'dart:ui' as ui;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Distinct emoji kept baked at once; a stamp already painted keeps its own copy.
const canvasEmojiBitmapsKept = 64;

class CanvasEmojiHydrator {
  CanvasEmojiHydrator({required this.document, required this.bake});

  final CanvasDocument document;

  /// A bitmap of the emoji under [key] for this hydrator to own, or null when it cannot be had.
  final Future<ui.Image?> Function(String key) bake;

  // Insertion order is the use order, so the first is evicted.
  final _baked = <String, ui.Image>{};
  final _loads = <String, Future<ui.Image?>>{};
  final _pending = <String>{};
  bool _disposed = false;

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

  void _request(String id, String key) {
    if (!_pending.add(id)) return;
    _load(id, key);
  }

  Future<void> _load(String id, String key) async {
    try {
      final image = await _bitmap(key);
      if (_disposed) return;
      if (image == null) {
        document.markImageLoadFailed(id);
      } else {
        document.setImageBitmap(id, image.clone());
      }
    } finally {
      _pending.remove(id);
    }
  }

  Future<ui.Image?> _bitmap(String key) {
    final held = _baked.remove(key);
    if (held != null) return Future.value(_baked[key] = held);
    return _loads[key] ??= bake(key)
        .then((image) {
          if (image == null) return null;
          if (_disposed) {
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
          _loads.remove(key);
        });
  }

  void dispose() {
    _disposed = true;
    for (final image in _baked.values) {
      image.dispose();
    }
    _baked.clear();
  }
}
