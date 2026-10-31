// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When and how the sync controller reconnects: backoff timers, a socket cut for lagging, and the app returning to the foreground.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_lifecycle.dart';
import 'reconnect_backoff.dart';
import 'sync_frame_queue.dart';
import 'sync_status.dart';

class SyncReconnector {
  SyncReconnector({
    required Ref ref,
    required this.backoff,
    required this.start,
    required this.isDisposed,
    required this.wantsConnection,
    required this.status,
    required this.generation,
    required this.probe,
    required this.failConnect,
  }) : _ref = ref;

  final Ref _ref;
  final ReconnectBackoff backoff;
  final Future<void> Function() start;
  final bool Function() isDisposed;
  final bool Function() wantsConnection;
  final SyncStatus Function() status;
  final int Function() generation;

  /// Null while no socket is held; otherwise whether it still answers.
  final Future<bool>? Function() probe;
  final void Function(Object error, StackTrace stack) failConnect;

  Timer? _retry;
  int _overflowRestarts = 0;

  /// A phone in the background gets its messages by push; retrying there only burns battery.
  bool get _backgroundedOnPhone =>
      _ref.read(mobileLifecycleHostProvider) &&
      _ref.read(appLifecycleProvider) != AppLifecycleState.resumed;

  /// Backs off, and jitters, so a server restart does not bring every client
  /// back in the same instant. See [ReconnectBackoff] for the delay itself;
  /// this only schedules the timer it returns.
  void scheduleRetry() {
    if (isDisposed() || _backgroundedOnPhone) return;
    _retry?.cancel();
    _retry = Timer(backoff.next(), start);
  }

  void cancelRetry() => _retry?.cancel();

  /// A connect went live: forget the failures and the overflow restarts.
  void connected() {
    backoff.connected();
    _overflowRestarts = 0;
  }

  /// A socket cut for lagging reconnects at once only if it had been healthy;
  /// one that keeps lagging straight after connecting backs off like any drop.
  Future<void> resyncAfterLag() async {
    if (backoff.stable) {
      await start();
      return;
    }
    backoff.dropped();
    scheduleRetry();
  }

  void onLifecycle(AppLifecycleState? previous, AppLifecycleState next) {
    if (next != AppLifecycleState.resumed || previous == next) return;
    unawaited(_checkOnResume());
  }

  /// Returning to the foreground reconnects now rather than waiting out a
  /// backoff, and probes a socket the OS may have killed while asleep.
  Future<void> _checkOnResume() async {
    if (isDisposed() || !wantsConnection()) return;
    if (status() == SyncStatus.connecting) return;
    final at = generation();
    if (status() == SyncStatus.live) {
      final alive = probe();
      if (alive != null &&
          (await alive || at != generation() || isDisposed())) {
        return;
      }
    }
    await start();
  }

  /// A busy stream on a healthy connection resyncs soon with no failure status, a few times; then it is a failure.
  void onBacklogOverflow(Object error, StackTrace stack) {
    if (_overflowRestarts >= maxQuickOverflowRestarts) {
      failConnect(error, stack);
      return;
    }
    _overflowRestarts++;
    _retry?.cancel();
    _retry = Timer(backoff.step * _overflowRestarts, start);
  }
}
