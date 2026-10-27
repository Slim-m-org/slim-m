// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SyncController]'s reaction to the app leaving and returning to the
/// foreground, to a server that cut the socket for lagging, and to a connect that failed.
part of 'sync_controller.dart';

extension SyncControllerResume on SyncController {
  /// A phone in the background gets its messages by push; retrying there only burns battery.
  bool get _backgroundedOnPhone =>
      _ref.read(mobileLifecycleHostProvider) &&
      _ref.read(appLifecycleProvider) != AppLifecycleState.resumed;

  /// A socket cut for lagging reconnects at once only if it had been healthy;
  /// one that keeps lagging straight after connecting backs off like any drop.
  Future<void> _resyncAfterLag() async {
    if (_backoff.stable) {
      await start();
      return;
    }
    _backoff.dropped();
    _scheduleRetry();
  }

  void _onLifecycle(AppLifecycleState? previous, AppLifecycleState next) {
    if (next != AppLifecycleState.resumed || previous == next) return;
    unawaited(_checkOnResume());
  }

  /// Returning to the foreground reconnects now rather than waiting out a
  /// backoff, and probes a socket the OS may have killed while asleep.
  Future<void> _checkOnResume() async {
    if (_disposed || !_wantsConnection) return;
    if (_status == SyncStatus.connecting) return;
    final generation = _generation;
    final connection = _connection;
    if (_status == SyncStatus.live && connection != null) {
      final alive = await connection.probe();
      if (alive || generation != _generation || _disposed) return;
    }
    await start();
  }

  /// A busy stream on a healthy connection resyncs soon with no failure status, a few times; then it is a failure.
  void _onBacklogOverflow(Object error, StackTrace stack) {
    if (_overflowRestarts >= maxQuickOverflowRestarts) {
      _failConnect(error, stack);
      return;
    }
    _overflowRestarts++;
    _retry?.cancel();
    _retry = Timer(_backoff.step * _overflowRestarts, start);
  }
}
