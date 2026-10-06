// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning an [ImageOp]'s bytes into something a painter can draw.
///
/// A `CustomPainter` cannot await, and decoding a raster image is asynchronous,
/// so an image cannot be painted the way every other op is. This closes that
/// gap without giving up the contract that ops paint in the order they were
/// sent: the decode happens here, off to one side, and the painter draws
/// whichever images are ready in their proper place in the list. One that has
/// not finished simply does not draw yet, and a frame later it does.
///
/// Overlaying `Image.memory` widgets would have been less code and the wrong
/// shape: widgets stack above the canvas, so an image would always have covered
/// every painted op regardless of where the module put it, and a rect drawn
/// after an image could never hide it.
///
/// Three ceilings, because this is the one op whose cost a module chooses:
///
/// - the payload itself is bounded at parse ([ImageOp.maxEncodedLength]) and the
///   count per scene with it, so nothing here ever sees an oversized one
/// - the declared pixel size is bounded before decoding ([sceneImageMaxPixels]),
///   because a few KB of png can claim a bitmap of hundreds of megabytes, and
///   what is kept is at most [sceneImageMaxSide] on the long side
/// - decoded bitmaps are bounded by total bytes, because decoding is where a
///   64k payload becomes megabytes of pixels. An LRU evicts the
///   least-recently-drawn that the scene on screen does not use, so a scene
///   cycling through more images than fit stays correct and merely re-decodes
///   across scenes; the images of the scene being shown are never evicted,
///   because evicting one only starts a decode that evicts another.
///
/// The same instincts `canvas_image_hydrator.dart` already applies to canvas
/// images, at a smaller scale and without the network.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'bounded_image_decode.dart';
import 'module_scene.dart';

/// The longer side a kept bitmap is decoded to at most.
const sceneImageMaxSide = 1024;

/// The most pixels a payload may declare before it is refused undecoded.
const sceneImageMaxPixels = 2048 * 2048;

class SceneImageCache extends ChangeNotifier {
  SceneImageCache({this.maxDecodedBytes = _defaultMaxDecodedBytes});

  /// Roughly two 1024x1024 bitmaps. A scene is a small surface, and the point of
  /// the bound is that a module cycling images cannot grow a client's memory
  /// without limit, not that it can hold a gallery.
  static const _defaultMaxDecodedBytes = 8 * 1024 * 1024;

  final int maxDecodedBytes;

  final _ready = <int, ui.Image>{};
  final _pending = <int>{};

  /// Keys whose bytes could not be decoded. Kept so a broken payload is
  /// attempted once rather than on every frame, which for a module re-emitting
  /// its scene would be a decode attempt several times a second forever.
  final _failed = <int>{};

  /// Least-recently-drawn first.
  final _lru = <int>[];

  /// The image keys of the scene [snapshot] was last asked for: never evicted.
  var _wanted = <int>{};

  var _decodedBytes = 0;
  var _disposed = false;

  /// The decoded images for [scene], requesting any that are missing.
  ///
  /// Returns a fresh map so the painter can compare identity to decide whether
  /// to repaint, and so nothing it holds can change under it mid-paint.
  Map<int, ui.Image> snapshot(ModuleScene scene) {
    final wanted = <int, ui.Image>{};
    _wanted = {
      for (final op in scene.ops)
        if (op is ImageOp) op.key,
    };
    for (final op in scene.ops) {
      if (op is! ImageOp) continue;
      final image = _ready[op.key];
      if (image != null) {
        wanted[op.key] = image;
        _touch(op.key);
        continue;
      }
      if (_pending.contains(op.key) || _failed.contains(op.key)) continue;
      _pending.add(op.key);
      unawaited(_decode(op.key, op.bytes));
    }
    return wanted;
  }

  Future<void> _decode(int key, Uint8List bytes) async {
    try {
      final image = await decodeBoundedImage(
        bytes,
        maxSide: sceneImageMaxSide,
        maxSourcePixels: sceneImageMaxPixels,
      );
      if (_disposed) {
        image.dispose();
        return;
      }
      _pending.remove(key);
      _remember(key, image);
      notifyListeners();
    } catch (_) {
      // Not a decodable image is a real answer, so nothing retries it.
      if (_disposed) return;
      _pending.remove(key);
      _failed.add(key);
    }
  }

  void _remember(int key, ui.Image image) {
    _ready[key] = image;
    _decodedBytes += _bytesOf(image);
    _lru.add(key);
    for (final victim in _lru.toList()) {
      if (_decodedBytes <= maxDecodedBytes) break;
      if (!_wanted.contains(victim)) _evict(victim);
    }
  }

  void _touch(int key) {
    if (_lru.remove(key)) _lru.add(key);
  }

  void _evict(int key) {
    _lru.remove(key);
    final image = _ready.remove(key);
    if (image == null) return;
    _decodedBytes -= _bytesOf(image);
    image.dispose();
  }

  static int _bytesOf(ui.Image image) => image.width * image.height * 4;

  /// Test-only: how much decoded bitmap is currently held.
  @visibleForTesting
  int get decodedBytes => _decodedBytes;

  /// Test-only: whether a key was tried and could not be decoded.
  @visibleForTesting
  bool hasFailed(int key) => _failed.contains(key);

  @override
  void dispose() {
    _disposed = true;
    for (final image in _ready.values) {
      image.dispose();
    }
    _ready.clear();
    _lru.clear();
    _decodedBytes = 0;
    super.dispose();
  }
}
