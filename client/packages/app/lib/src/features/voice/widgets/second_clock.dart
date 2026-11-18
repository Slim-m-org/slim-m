// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One shared 1 Hz source for every on-screen clock. It runs while some readout
/// is subscribed and the window is on screen, focused or not: a call is often
/// watched from beside a game. A hidden or minimised window spends nothing.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_lifecycle.dart'
    show appLifecycleProvider, isWindowVisible;

class SecondClock {
  SecondClock._();

  static final instance = SecondClock._();

  final _listeners = <VoidCallback>{};
  Timer? _timer;
  ProviderContainer? _source;
  ProviderSubscription<AppLifecycleState>? _lifecycle;
  AppLifecycleState? _state;

  bool get isRunning => _timer != null;

  bool get _onScreen {
    final state = _state;
    return state == null || isWindowVisible(state);
  }

  /// Takes the window's state from [container]'s [appLifecycleProvider], which
  /// corrects what the embedder reports; null forgets it and runs whenever wanted.
  void follow(ProviderContainer? container) {
    if (container == _source) return;
    _lifecycle?.close();
    _lifecycle = null;
    _source = container;
    _state = null;
    if (container != null) {
      _lifecycle = container.listen<AppLifecycleState>(
        appLifecycleProvider,
        (_, state) => _onLifecycle(state),
        fireImmediately: true,
      );
    }
    _sync();
  }

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    _sync();
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    _sync();
  }

  void _onLifecycle(AppLifecycleState state) {
    _state = state;
    _sync();
    // A clock that sat out a hidden window is stale the moment it shows again.
    if (_timer != null) _notify();
  }

  void _sync() {
    final wanted = _listeners.isNotEmpty && _onScreen;
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
