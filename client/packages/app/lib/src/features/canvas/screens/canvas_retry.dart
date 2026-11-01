// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One idempotent retry shared by every canvas write, so a blip or a deploy
/// never costs the person the ink, note or edit they just made.
library;

import 'dart:math' as math;

import 'package:slimm_api/api.dart' as api;

const Duration _firstDelay = Duration(milliseconds: 250);
const Duration _maxDelay = Duration(seconds: 8);
const Duration _maxRetryAfter = Duration(seconds: 30);

/// Whether sending the same request again can still succeed: a throttle, a
/// shed request, a dropped connection, or a proxy answering mid-deploy.
bool isTransientCanvasFailure(api.ApiException error) => switch (error) {
  api.RateLimitedException() ||
  api.UnavailableException() ||
  api.TransportException() => true,
  api.NotFoundException(:final unexplained) => unexplained,
  // A gateway answering for a restarting server, not the server's own 500.
  api.ServerException(:final statusCode) =>
    statusCode == 502 || statusCode == 504,
  _ => false,
};

/// Reruns [send] after a transient failure with the same request (so the idempotency key makes a lost reply harmless), backing off and honouring `retryAfter`.
/// Rethrows after [maxAttempts] (null retries until [giveUp] says stop), and at once for anything a retry cannot fix.
/// [onRetry] runs when a failure is about to be retried, so the caller can say the change is not saved yet.
Future<T> retryCanvasRequest<T>(
  Future<T> Function() send, {
  int? maxAttempts = 6,
  bool Function()? giveUp,
  void Function()? onRetry,
}) async {
  var delay = _firstDelay;
  for (var attempt = 1; ; attempt++) {
    try {
      return await send();
    } on api.ApiException catch (error) {
      final exhausted = maxAttempts != null && attempt >= maxAttempts;
      if (!isTransientCanvasFailure(error) || exhausted) rethrow;
      if (giveUp?.call() ?? false) rethrow;
      onRetry?.call();
      await Future<void>.delayed(_waitBefore(error, delay));
      if (giveUp?.call() ?? false) rethrow;
      delay = _atMost(delay * 2, _maxDelay);
    }
  }
}

Duration _waitBefore(api.ApiException error, Duration delay) {
  final after = error is api.RateLimitedException ? error.retryAfter : null;
  return after == null
      ? delay
      : _atMost(_atLeast(after, delay), _maxRetryAfter);
}

Duration _atLeast(Duration a, Duration b) => a > b ? a : b;

Duration _atMost(Duration a, Duration b) =>
    Duration(microseconds: math.min(a.inMicroseconds, b.inMicroseconds));
