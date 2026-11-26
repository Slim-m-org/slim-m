// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `/tts` request, so the composer's widgets never reach the API client themselves.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

/// Asks the server to speak a line into a channel's call; see decision 0142.
final ttsSpeakProvider = Provider<Future<int> Function(String, String)>(
  (ref) =>
      (channelId, text) => ref.read(apiProvider).speakTts(channelId, text),
);

/// Fires when a line this account typed in [channelId] was accepted and then could not be spoken.
final ttsFailedProvider = StreamProvider.autoDispose.family<void, String>(
  (ref, channelId) => ref
      .watch(liveEventsProvider)
      .where((event) => event is TtsFailed && event.channelId == channelId),
);
