// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Zoom and pan of a watched share, kept as fractions of the viewport.
///
/// Fractions rather than pixels, so the state means the same in a tile, the
/// focused view and full screen. A viewport point `p` (0 to 1 each way) is
/// drawn at `p * scale + origin`; [origin] is never positive and never leaves
/// the picture's edge short of the viewport's.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

const shareZoomMax = 8.0;

/// The zoom a double click or tap jumps to from fit.
const shareZoomToggleScale = 2.0;

/// Multiplier for one +/- key press.
const shareZoomKeyStep = 1.25;

/// Scale gained per scrolled pixel of a mouse wheel.
const shareZoomWheelRate = 0.002;

class ShareZoomController extends ChangeNotifier {
  double _scale = 1;
  Offset _origin = Offset.zero;

  double get scale => _scale;

  /// Where the viewport's top-left lands, as a fraction of the viewport; zero or less.
  Offset get origin => _origin;

  bool get zoomed => _scale > 1.001;

  /// Whole percent, 100 being fit.
  int get percent => (_scale * 100).round();

  /// [rect], in viewport pixels at fit, as it is drawn now.
  Rect apply(Rect rect, Size viewport) => Rect.fromLTWH(
    rect.left * _scale + _origin.dx * viewport.width,
    rect.top * _scale + _origin.dy * viewport.height,
    rect.width * _scale,
    rect.height * _scale,
  );

  /// Scales by [factor] keeping the viewport point [focal] (0 to 1) where it is.
  void zoomAt(double factor, Offset focal) {
    final next = (_scale * factor).clamp(1.0, shareZoomMax);
    if (next == _scale) return;
    final ratio = next / _scale;
    _set(next, focal - (focal - _origin) * ratio);
  }

  /// Moves the picture by [delta], a fraction of the viewport.
  void panBy(Offset delta) {
    if (!zoomed) return;
    _set(_scale, _origin + delta);
  }

  void reset() => _set(1, Offset.zero);

  /// Fit to [shareZoomToggleScale] around [focal], or back to fit when already zoomed.
  void toggle([Offset focal = const Offset(0.5, 0.5)]) {
    if (zoomed) {
      reset();
    } else {
      zoomAt(shareZoomToggleScale, focal);
    }
  }

  /// Handles + / - / 0 around the viewport's centre.
  KeyEventResult handleKey(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    const centre = Offset(0.5, 0.5);
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      zoomAt(shareZoomKeyStep, centre);
    } else if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      zoomAt(1 / shareZoomKeyStep, centre);
    } else if (key == LogicalKeyboardKey.digit0 ||
        key == LogicalKeyboardKey.numpad0) {
      reset();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _set(double scale, Offset origin) {
    final clamped = Offset(
      origin.dx.clamp(1 - scale, 0.0),
      origin.dy.clamp(1 - scale, 0.0),
    );
    final next = scale <= 1.0 ? Offset.zero : clamped;
    if (scale == _scale && next == _origin) return;
    _scale = math.max(1.0, scale);
    _origin = next;
    notifyListeners();
  }
}

/// One zoom per tile key, so the video and its controls on the canvas read the same state.
class ShareZoomSet {
  final Map<String, ShareZoomController> _byKey = {};

  ShareZoomController of(String key) =>
      _byKey.putIfAbsent(key, ShareZoomController.new);

  /// Forgets the zoom of every tile not in [keys], so a share that ends and starts again begins at fit.
  void keepOnly(Set<String> keys) =>
      _byKey.removeWhere((key, _) => !keys.contains(key));
}
