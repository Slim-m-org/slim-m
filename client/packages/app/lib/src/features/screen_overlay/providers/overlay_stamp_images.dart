// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which stamp pictures the overlay runner holds, so each PNG crosses the
/// channel once and a draw frame only names it (decision 0121).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';

/// Pictures the runner holds at once; the least recently used is dropped past this.
const overlayStampImagesKept = 24;

class OverlayStampImages {
  OverlayStampImages(this._window);

  final ScreenOverlay _window;

  // Insertion order is the use order, so the first is the least recently used.
  final _held = <String>{};
  final _puts = <String, Future<bool>>{};
  var _generation = 0;

  bool has(String key) => _held.contains(key);

  /// Puts [key]'s picture on the runner once, baking it with [bake]; true once the runner holds it.
  Future<bool> ensure(String key, Future<Uint8List> Function() bake) {
    if (_held.remove(key)) {
      _held.add(key);
      return Future.value(true);
    }
    final pending = _puts[key];
    if (pending != null) return pending;
    final put = _put(key, bake, _generation);
    _puts[key] = put;
    unawaited(
      put.whenComplete(() {
        if (identical(_puts[key], put)) _puts.remove(key);
      }),
    );
    return put;
  }

  /// The window was shown or hidden, and the runner forgot every picture with it.
  void forget() {
    _generation++;
    _held.clear();
    _puts.clear();
  }

  Future<bool> _put(
    String key,
    Future<Uint8List> Function() bake,
    int generation,
  ) async {
    try {
      final png = await bake();
      if (generation != _generation) return false;
      final held = await _window.putImage(key, png);
      if (!held || generation != _generation) return false;
      _held.add(key);
      while (_held.length > overlayStampImagesKept) {
        final oldest = _held.first;
        _held.remove(oldest);
        unawaited(_window.dropImage(oldest));
      }
      return true;
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'A stamp picture did not reach the screen overlay; it is not drawn there',
        error,
        stack,
      );
      return false;
    }
  }
}
