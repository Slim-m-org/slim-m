// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ends an upload that stopped moving, ran too long or was cancelled.
library;

import 'dart:async';

import 'upload_source.dart';

/// Watches one upload send: a stall timer that [touch] pushes back, an
/// optional ceiling on the whole send, and a cancel token.
///
/// Whichever fires first completes [abortTrigger], so the client closes the
/// request, and fails [guard] with a [TimeoutException] or [UploadCancelled].
class UploadGuard {
  UploadGuard({this.stall, Duration? total, UploadCancelToken? cancel}) {
    if (total != null) _total = Timer(total, _timedOut);
    _failure.future.ignore();
    _arm();
    cancel?.whenCancelled.then((_) => _fail(const UploadCancelled()));
  }

  final Duration? stall;
  final _abort = Completer<void>();
  final _failure = Completer<Never>();
  Timer? _stalled;
  Timer? _total;

  /// Completes once the guard gave up on the send.
  Future<void> get abortTrigger => _abort.future;

  bool get stopped => _abort.isCompleted;

  /// Notes that bytes moved, pushing the stall window back.
  void touch() => _arm();

  /// Replaces the stall window, for the wait on the server once the body is out.
  void rearm(Duration window) => _arm(window);

  /// Resolves like [work], or fails first when the guard gives up.
  Future<T> guard<T>(Future<T> work) => Future.any([work, _failure.future]);

  void dispose() {
    _stalled?.cancel();
    _total?.cancel();
  }

  void _arm([Duration? window]) {
    final limit = window ?? stall;
    if (limit == null || stopped) return;
    _stalled?.cancel();
    _stalled = Timer(limit, _timedOut);
  }

  void _timedOut() => _fail(TimeoutException('the upload stopped moving'));

  void _fail(Object error) {
    if (stopped) return;
    dispose();
    _abort.complete();
    _failure.completeError(error);
  }
}
