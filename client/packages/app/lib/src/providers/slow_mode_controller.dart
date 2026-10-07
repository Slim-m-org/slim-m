// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's own slow-mode countdown: soft-blocks a send client-side
/// between the interval a channel's `slowModeSeconds` sets, rather than
/// letting a member type, tap send, and learn about the wait from a 429.
///
/// The server is still the only authority - see
/// `crates/slimm-server/src/http/channel_slow_mode.rs::enforce_slow_mode` -
/// this only avoids the round trip in the common case. It can under-block
/// (a second device sent more recently than this one knows, or slow mode
/// was just raised) or over-block for a beat after a stale local clock; both
/// are harmless, since a send this misses still goes to the server, and a
/// send this wrongly allows is refused there and shown through the
/// composer's ordinary failed-send path (see `describeApiFailure`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../permissions.dart';
import 'channel_by_id_provider.dart';
import 'channel_permissions.dart';

/// Seconds remaining before slow mode allows another send, given the
/// channel's interval and when this device last had one accepted here.
/// Pure and clock-injected so a test never depends on wall-clock timing.
int slowModeRemainingSeconds({
  required int slowModeSeconds,
  required DateTime? lastSentAt,
  required DateTime now,
}) {
  if (slowModeSeconds <= 0 || lastSentAt == null) return 0;
  final windowMs = slowModeSeconds * 1000;
  final elapsedMs = now.difference(lastSentAt).inMilliseconds;
  if (elapsedMs >= windowMs) return 0;
  final remainingMs = windowMs - elapsedMs;
  // Rounds up, the same direction the server's own remaining-seconds does, so a client that waits the displayed count is never a beat early.
  return ((remainingMs + 999) ~/ 1000).clamp(1, slowModeSeconds);
}

/// When this device last had a message accepted in each channel, by channel
/// id. Not persisted: a fresh launch shows no countdown until this device's
/// own next accepted send, same as a second device that was never told.
class SlowModeLastSent extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() => const {};

  /// Recorded at the device's own time on a successful send (see
  /// `sendOptimistically`), because the countdown compares it against the
  /// device clock; it trails the server's stamp by about one round trip.
  void recordSent(String channelId, DateTime at) {
    final current = state[channelId];
    if (current != null && !at.isAfter(current)) return;
    state = {...state, channelId: at};
  }
}

final slowModeLastSentProvider =
    NotifierProvider<SlowModeLastSent, Map<String, DateTime>>(
      SlowModeLastSent.new,
    );

/// Ticks once a second purely to force [slowModeRemainingSecondsProvider]'s
/// watchers to recompute; carries no state of its own worth reading.
/// `autoDispose` so it stops the moment nothing is counting down.
final slowModeTickerProvider = StreamProvider.autoDispose<void>(
  (ref) => Stream.periodic(const Duration(seconds: 1)),
);

/// The countdown a channel's composer shows and soft-blocks send with: 0
/// while slow mode is off, the caller holds `MANAGE_CHANNELS` here, or this
/// device has never sent (or waited long enough since it last did).
final slowModeRemainingSecondsProvider = Provider.autoDispose
    .family<int, String>((ref, channelId) {
      final seconds =
          ref
              .watch(channelByIdProvider(channelId))
              .valueOrNull
              ?.slowModeSeconds ??
          0;
      if (seconds <= 0) return 0;
      final exempt = ref
          .watch(myChannelPermissionsProvider(channelId))
          .hasPermission(Perm.manageChannels);
      if (exempt) return 0;
      ref.watch(slowModeTickerProvider);
      final lastSentAt = ref.watch(slowModeLastSentProvider)[channelId];
      return slowModeRemainingSeconds(
        slowModeSeconds: seconds,
        lastSentAt: lastSentAt,
        now: DateTime.now(),
      );
    });
