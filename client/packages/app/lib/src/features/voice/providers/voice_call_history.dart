// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel's call history (decision 0066) for its idle pane,
/// refetched shortly after anything changes in that channel's call.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

/// Long enough for the server's webhook write to land before the refetch.
const voiceCallHistoryRefreshDelay = Duration(seconds: 2);

final voiceCallHistoryProvider = FutureProvider.autoDispose
    .family<api.VoiceCallHistory, String>((ref, channelId) async {
      Timer? pending;
      final sub = ref.read(liveEventsProvider).listen((event) {
        final changed = switch (event) {
          api.VoiceActivityChanged(:final channelId) ||
          api.VoiceParticipantJoined(:final channelId) ||
          api.VoiceParticipantLeft(:final channelId) ||
          api.VoiceScreenShareChanged(:final channelId) => channelId,
          _ => null,
        };
        if (changed != channelId) return;
        pending?.cancel();
        pending = Timer(voiceCallHistoryRefreshDelay, ref.invalidateSelf);
      });
      ref.onDispose(() {
        pending?.cancel();
        unawaited(sub.cancel());
      });
      try {
        return await ref.watch(apiProvider).listVoiceCalls(channelId);
      } on api.NotFoundException {
        // A server too old to keep history: the pane shows its join bar alone.
        return const api.VoiceCallHistory(
          retentionDays: 0,
          canvasObjectCount: 0,
          calls: [],
        );
      }
    });

/// Which earlier call the pane's timeline shows, by its start time; null
/// for the most recent one.
final selectedVoiceCallProvider = StateProvider.autoDispose
    .family<int?, String>((ref, channelId) => null);
