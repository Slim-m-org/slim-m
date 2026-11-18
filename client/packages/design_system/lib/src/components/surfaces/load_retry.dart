// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed fetch that tries again on its own, so a passing 429 or outage
/// never leaves a panel stuck until someone presses Retry.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The waits between automatic retries; the last one repeats.
const appLoadRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// How far a failing load has come through [appLoadRetryDelays], held by
/// whoever outlives one error view so a retry's own spinner does not reset it.
class AppLoadBackoff {
  var _attempt = 0;

  Duration get wait =>
      appLoadRetryDelays[math.min(_attempt, appLoadRetryDelays.length - 1)];

  void advance() => _attempt++;

  void reset() => _attempt = 0;
}

/// Which failed loads are worth trying again, for every AppAsyncView below
/// it; with none above, every failure is.
class AppLoadRetryPolicy extends InheritedWidget {
  const AppLoadRetryPolicy({
    super.key,
    required this.retries,
    required super.child,
  });

  /// False for a failure that retrying cannot fix, such as a lost permission.
  final bool Function(Object error) retries;

  static bool allows(BuildContext context, Object error) =>
      context
          .dependOnInheritedWidgetOfExactType<AppLoadRetryPolicy>()
          ?.retries(error) ??
      true;

  @override
  bool updateShouldNotify(AppLoadRetryPolicy oldWidget) =>
      retries != oldWidget.retries;
}

/// Calls [onRetry] on a backoff while on screen, and at once when the app comes back to the foreground.
class AppLoadRetry extends StatefulWidget {
  const AppLoadRetry({
    super.key,
    required this.onRetry,
    this.backoff,
    required this.child,
  });

  /// Null for a failure that retrying cannot fix, such as a lost permission.
  final VoidCallback? onRetry;

  /// Kept by a caller that rebuilds this between attempts; null keeps its own.
  final AppLoadBackoff? backoff;

  final Widget child;

  @override
  State<AppLoadRetry> createState() => _AppLoadRetryState();
}

class _AppLoadRetryState extends State<AppLoadRetry> {
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;
  final _ownBackoff = AppLoadBackoff();

  /// False in a hidden tab or under a covering route, where a retry helps nobody.
  var _onScreen = false;

  AppLoadBackoff get _backoff => widget.backoff ?? _ownBackoff;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _retry);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onScreen =
        TickerMode.valuesOf(context).enabled && Visibility.of(context);
    if (onScreen == _onScreen) return;
    _onScreen = onScreen;
    _schedule();
  }

  @override
  void didUpdateWidget(AppLoadRetry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.onRetry == null) != (widget.onRetry == null)) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (widget.onRetry == null || !_onScreen) return;
    _timer = Timer(_backoff.wait, _retry);
  }

  void _retry() {
    final retry = widget.onRetry;
    if (!mounted || !_onScreen || retry == null) return;
    _backoff.advance();
    retry();
    _schedule();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
