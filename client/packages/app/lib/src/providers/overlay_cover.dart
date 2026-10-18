// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How many sheets and dialogs sit over the page right now.
///
/// A route beneath a non-opaque route stays mounted and keeps ticking, and the
/// shell's pages live in a nested navigator whose own `isCurrent` never sees a
/// sheet pushed on the root one, so only the root navigator can say.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final overlayCoverProvider = StateProvider<int>((ref) => 0);

/// Attach to the root navigator; reports through [onChanged] after the frame's
/// build so a watcher is never marked dirty mid-build.
class OverlayCoverObserver extends NavigatorObserver {
  OverlayCoverObserver(this.onChanged);

  final void Function(int covering) onChanged;
  final _covering = <Route<dynamic>>{};

  bool _isOverlay(Route<dynamic> route) => route is ModalRoute && !route.opaque;

  void _report() {
    final count = _covering.length;
    scheduleMicrotask(() => onChanged(count));
  }

  void _add(Route<dynamic>? route) {
    if (route != null && _isOverlay(route)) _covering.add(route);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _add(route);
    _report();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _covering.remove(oldRoute);
    _add(newRoute);
    _report();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _covering.remove(route);
    _report();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _covering.remove(route);
    _report();
  }
}
