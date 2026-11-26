// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `/tts` request, so the composer's widgets never reach the API client themselves.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

/// Asks the server to speak a line into a channel's call; see decision 0142.
final ttsSpeakProvider = Provider<Future<int> Function(String, String)>(
  (ref) =>
      (channelId, text) => ref.read(apiProvider).speakTts(channelId, text),
);

/// Tells the composer when a line this account typed in its channel was accepted and then could not be spoken.
///
/// One subscription at a time, dropped by [release] or when the channel changes, so a composer never leaves one behind.
class TtsFailureWatch {
  StreamSubscription<ServerEvent>? _subscription;

  void bind(WidgetRef ref, String channelId, void Function() onFailed) {
    unawaited(_subscription?.cancel());
    _subscription = ref
        .read(liveEventsProvider)
        .where((event) => event is TtsFailed && event.channelId == channelId)
        .listen((_) => onFailed());
  }

  void release() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
