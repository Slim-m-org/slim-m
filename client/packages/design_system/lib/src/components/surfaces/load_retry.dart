// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed fetch that tries again on its own, so a passing 429 or outage
/// never leaves a panel stuck until someone presses Retry.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// The waits between automatic retries; the last one repeats.
const appLoadRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// Calls [onRetry] on a backoff while shown, and at once when the app comes back to the foreground.
class AppLoadRetry extends StatefulWidget {
  const AppLoadRetry({super.key, required this.onRetry, required this.child});

  /// Null for a failure that retrying cannot fix, such as a lost permission.
  final VoidCallback? onRetry;
  final Widget child;

  @override
  State<AppLoadRetry> createState() => _AppLoadRetryState();
}

class _AppLoadRetryState extends State<AppLoadRetry> {
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;
  var _attempt = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _retry);
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
    if (widget.onRetry == null) return;
    final delays = appLoadRetryDelays;
    _timer = Timer(delays[_attempt.clamp(0, delays.length - 1)], _retry);
  }

  void _retry() {
    final retry = widget.onRetry;
    if (!mounted || retry == null) return;
    _attempt++;
    retry();
    _schedule();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
