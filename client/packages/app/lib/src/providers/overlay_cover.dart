// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which sheets and dialogs sit over which routes right now.
///
/// A route beneath a non-opaque route stays mounted and keeps ticking, and the
/// shell's pages live in a nested navigator whose own `isCurrent` never sees a
/// sheet pushed on the root one, so only the root navigator can say.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The non-opaque routes on the root navigator, bottom first.
class OverlayStack {
  const OverlayStack(this._routes);

  static const empty = OverlayStack(<Route<dynamic>>[]);

  final List<Route<dynamic>> _routes;

  /// Whether a sheet or dialog sits above [route], which an overlay never does to itself.
  ///
  /// A route the root navigator never reported, such as a page in the shell's
  /// nested navigator, lies beneath every overlay.
  bool covers(Route<dynamic>? route) {
    final at = route == null ? -1 : _routes.indexOf(route);
    return at < 0 ? _routes.isNotEmpty : at < _routes.length - 1;
  }
}

final overlayCoverProvider = StateProvider<OverlayStack>(
  (ref) => OverlayStack.empty,
);

/// Attach to the root navigator; reports through [onChanged] after the frame's
/// build so a watcher is never marked dirty mid-build.
class OverlayCoverObserver extends NavigatorObserver {
  OverlayCoverObserver(this.onChanged);

  final void Function(OverlayStack stack) onChanged;
  final _overlays = <Route<dynamic>>[];

  bool _isOverlay(Route<dynamic> route) => route is ModalRoute && !route.opaque;

  void _report() {
    final stack = OverlayStack(List.unmodifiable(_overlays));
    scheduleMicrotask(() => onChanged(stack));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isOverlay(route)) _overlays.add(route);
    _report();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _overlays.indexOf(oldRoute);
    final replacement = newRoute != null && _isOverlay(newRoute)
        ? newRoute
        : null;
    if (at < 0) {
      if (replacement != null) _overlays.add(replacement);
    } else if (replacement != null) {
      _overlays[at] = replacement;
    } else {
      _overlays.removeAt(at);
    }
    _report();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _overlays.remove(route);
    _report();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _overlays.remove(route);
    _report();
  }
}
