// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own call stats (decision 0113): read on demand from the server and kept nowhere.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../settings/providers/device_timezone.dart';

/// The Space's transcription mode; stats exist only where it is not off.
final callTranscriptionModeProvider =
    FutureProvider.autoDispose<api.CallTranscriptionMode>((ref) async {
      final notice = await ref.watch(apiProvider).transcriptionNotice();
      return notice.mode;
    });

/// Whether the Space transcribes at all; false until the mode is known, so no pane appears on a guess.
final callStatsAvailableProvider = Provider.autoDispose<bool>((ref) {
  final mode = ref.watch(callTranscriptionModeProvider).valueOrNull;
  return mode != null && mode != api.CallTranscriptionMode.off;
});

/// The caller's numbers over the last [days] days, or everything kept when null.
final myCallStatsProvider = FutureProvider.autoDispose.family<api.CallStats, int?>((
  ref,
  days,
) async {
  final zone = await ref
      .watch(deviceTimezoneProvider.future)
      .then<String?>(
        (name) => name,
        // An unreadable zone only moves the day buckets, so the stats ask for UTC.
        onError: (_) => null,
      );
  return ref.watch(apiProvider).myCallStats(days: days, timezone: zone);
});

/// The caller's own numbers for one call; a call they did not speak in reads as empty.
final myCallStatsForCallProvider = FutureProvider.autoDispose
    .family<api.CallStats?, String>((ref, transcriptId) async {
      try {
        return await ref
            .watch(apiProvider)
            .myCallStats(transcriptId: transcriptId);
      } on api.ApiException {
        return null;
      }
    });
