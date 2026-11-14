// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice message transcripts that arrived live, by attachment id. A fetched
/// message carries its transcript itself; this only holds what a frame
/// delivered after the message was read, and wins over it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';

class VoiceTranscripts extends Notifier<Map<String, api.VoiceTranscript>> {
  @override
  Map<String, api.VoiceTranscript> build() {
    final sub = ref.watch(liveEventsProvider).listen((event) {
      if (event case api.MessageVoiceTranscript(
        :final attachmentId,
        :final transcript,
      )) {
        state = {...state, attachmentId: transcript};
      }
    });
    ref.onDispose(() => unawaited(sub.cancel()));
    return const {};
  }
}

final voiceTranscriptsProvider =
    NotifierProvider<VoiceTranscripts, Map<String, api.VoiceTranscript>>(
      VoiceTranscripts.new,
    );
