// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel's call history (decision 0066) for its idle pane, kept for
/// the last few channels visited and refetched after their call changes.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/cache_for.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

/// Long enough for the server's webhook write to land before the refetch.
const voiceCallHistoryRefreshDelay = Duration(seconds: 2);

/// Enough voice channels to move between without any of them reloading.
final _recent = KeepAliveCache(8);

final voiceCallHistoryProvider = FutureProvider.autoDispose
    .family<api.VoiceCallHistory, String>((ref, channelId) async {
      _recent.hold(ref, channelId);
      Timer? pending;
      var watched = true;
      var stale = false;
      var disposed = false;
      // Unwatched, a change only marks it stale, so the next visit still shows the old history while it refetches.
      void refresh() {
        if (watched) return ref.invalidateSelf();
        stale = true;
      }

      final sub = ref.read(liveEventsProvider).listen((event) {
        final changed = switch (event) {
          api.VoiceActivityChanged(:final channelId) ||
          api.VoiceParticipantJoined(:final channelId) ||
          api.VoiceParticipantLeft(:final channelId) ||
          api.VoiceScreenShareChanged(:final channelId) ||
          api.CallTranscriptChanged(:final channelId) => channelId,
          _ => null,
        };
        if (changed != channelId) return;
        pending?.cancel();
        pending = Timer(voiceCallHistoryRefreshDelay, refresh);
      });
      ref.onCancel(() => watched = false);
      ref.onResume(() {
        watched = true;
        if (!stale) return;
        stale = false;
        pending?.cancel();
        pending = Timer(Duration.zero, ref.invalidateSelf);
      });
      ref.onDispose(() {
        disposed = true;
        pending?.cancel();
        unawaited(sub.cancel());
      });
      try {
        return await ref.watch(apiProvider).listVoiceCalls(channelId);
      } on api.NotFoundException catch (error, stack) {
        api.AppLog.swallowed(
          api.LogTag.voice,
          'This channel has no call history on the server',
          error,
          stack,
        );
        // A server too old to keep history: the pane shows its empty state.
        return const api.VoiceCallHistory(
          retentionDays: 0,
          canvasObjectCount: 0,
          calls: [],
        );
      } catch (_) {
        // A build already replaced holds no link; the one under this key is its successor's.
        if (!disposed) _recent.release(channelId);
        rethrow;
      }
    });

/// Which earlier call the pane's timeline shows, by its start time; null
/// for the most recent one.
final selectedVoiceCallProvider = StateProvider.autoDispose
    .family<int?, String>((ref, channelId) => null);

/// A View details on the voice channel already on screen, for its call to
/// open its details: the route flag alone does not change on a second pick.
final callDetailsRequestProvider = StateProvider<({String channelId, int n})?>(
  (ref) => null,
);

void requestCallDetails(ProviderContainer container, String channelId) {
  final last = container.read(callDetailsRequestProvider);
  container.read(callDetailsRequestProvider.notifier).state = (
    channelId: channelId,
    n: (last?.n ?? 0) + 1,
  );
}
