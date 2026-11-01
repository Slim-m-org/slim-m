// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waiting out a refused background read instead of reporting it.
///
/// A read the user did not ask for just now (history paging, the sign-in
/// hydration, author lookups) that draws a 429 will almost always succeed a
/// moment later, so it is retried quietly. The server names how long to wait;
/// only when the budget is spent does the caller see the failure and surface
/// it on its persistent error state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../backoff.dart';

/// How many times a refused read is retried before the failure is reported.
const rateLimitRetries = 3;

/// The wait when the response named none, doubled on each further retry.
const rateLimitFallbackWait = Duration(milliseconds: 500);

/// The longest wait honoured. A refusal asking for more than this (a slow
/// mode in minutes, say) is not a blip, so it is reported rather than waited on.
const rateLimitMaxWait = Duration(seconds: 15);

typedef RateLimitWait = Future<void> Function(Duration);

/// The real wait, the default everywhere a test does not override it.
Future<void> sleepFor(Duration delay) => Future<void>.delayed(delay);

/// Overridden in tests so a retry does not sleep for real.
final rateLimitWaitProvider = Provider<RateLimitWait>((ref) => sleepFor);

/// Runs [run], retrying while it is refused with a rate limit.
///
/// Honours the server's own wait (`Retry-After`, or the body's
/// `retry_after_seconds`, both surfaced as [RateLimitedException.retryAfter]).
/// Rethrows the last refusal once [rateLimitRetries] retries are spent, or at
/// once when the server asked for longer than [rateLimitMaxWait]. Any other
/// failure passes straight through.
Future<T> retryWhenRateLimited<T>(
  Future<T> Function() run, {
  RateLimitWait wait = sleepFor,
}) async {
  const fallback = Backoff(base: rateLimitFallbackWait, cap: rateLimitMaxWait);
  for (var retry = 0; ; retry++) {
    try {
      return await run();
    } on RateLimitedException catch (refused) {
      final named = refused.retryAfter;
      if (retry >= rateLimitRetries) rethrow;
      if (named != null && named > rateLimitMaxWait) rethrow;
      await wait(named ?? fallback.delay(retry));
    }
  }
}
