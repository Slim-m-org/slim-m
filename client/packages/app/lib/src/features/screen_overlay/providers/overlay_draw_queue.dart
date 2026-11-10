// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hands the overlay window its frames one at a time and skips the ones that
/// repeat what it already shows.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:slimm_platform/platform.dart';

class OverlayDrawQueue {
  OverlayDrawQueue(this._window);

  final ScreenOverlay _window;
  List<OverlayShape> _shown = const [];
  List<OverlayShape>? _waiting;
  bool _inFlight = false;

  /// Paints [shapes] unless the window already shows them; while a draw is out, only the newest frame waits behind it.
  void draw(List<OverlayShape> shapes) {
    if (_inFlight) {
      _waiting = shapes;
      return;
    }
    if (listEquals(shapes, _shown)) return;
    unawaited(_send(shapes));
  }

  /// The window was shown or hidden, which leaves it blank.
  void reset() {
    _shown = const [];
    _waiting = null;
  }

  Future<void> _send(List<OverlayShape> first) async {
    _inFlight = true;
    try {
      var next = first;
      while (true) {
        _shown = next;
        await _window.draw(next);
        final waiting = _waiting;
        _waiting = null;
        if (waiting == null || listEquals(waiting, _shown)) return;
        next = waiting;
      }
    } finally {
      _inFlight = false;
    }
  }
}
