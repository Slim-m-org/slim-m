// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One shared 1 Hz source for every on-screen clock. It runs only while some
/// readout is subscribed and the app is focused, so a minimised window or a
/// covered route spends nothing on a number nobody can read.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

class SecondClock with WidgetsBindingObserver {
  SecondClock._();

  static final instance = SecondClock._();

  final _listeners = <VoidCallback>{};
  Timer? _timer;

  bool get isRunning => _timer != null;

  bool get _focused {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void addListener(VoidCallback listener) {
    if (_listeners.isEmpty) WidgetsBinding.instance.addObserver(this);
    _listeners.add(listener);
    _sync();
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) WidgetsBinding.instance.removeObserver(this);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _sync();
    // A clock that sat out the background is stale the moment focus returns.
    if (_timer != null) _notify();
  }

  void _sync() {
    final wanted = _listeners.isNotEmpty && _focused;
    if (wanted && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _notify());
    } else if (!wanted) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}

/// Rebuilds the state once a second while [tickWhile] was last given true and
/// the widget is not behind a route or tab that turned [TickerMode] off.
mixin SecondTickMixin<T extends StatefulWidget> on State<T> {
  bool _subscribed = false;

  void _onTick() {
    if (mounted) setState(() {});
  }

  /// Call from `build`; it only subscribes and never rebuilds by itself.
  void tickWhile(bool wanted) {
    final shouldRun = wanted && TickerMode.valuesOf(context).enabled;
    if (shouldRun == _subscribed) return;
    _subscribed = shouldRun;
    if (shouldRun) {
      SecondClock.instance.addListener(_onTick);
    } else {
      SecondClock.instance.removeListener(_onTick);
    }
  }

  @override
  void dispose() {
    if (_subscribed) SecondClock.instance.removeListener(_onTick);
    super.dispose();
  }
}
