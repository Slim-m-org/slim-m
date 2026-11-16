// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice message transcripts that arrived live, by attachment id. A fetched
/// message carries its transcript itself; this only holds what a frame
/// delivered after the message was read, and wins over it unless the message
/// has since moved further along.
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

/// The transcript a voice message shows: the [live] frame, unless the message
/// itself has moved further along, since frames are lossy and a refetch is the catch-up.
api.VoiceTranscript? shownVoiceTranscript(
  api.Attachment attachment,
  api.VoiceTranscript? live,
) {
  final fetched = attachment.transcript;
  if (live == null) return fetched;
  if (fetched == null) return live;
  return _progress(fetched.status) > _progress(live.status) ? fetched : live;
}

/// What a voice message was heard saying, or null until there are words.
String? voiceTranscriptWords(
  api.Attachment attachment,
  api.VoiceTranscript? live,
) {
  final shown = shownVoiceTranscript(attachment, live);
  if (shown == null || shown.status != api.VoiceTranscriptStatus.ready) {
    return null;
  }
  return shown.text.isEmpty ? null : shown.text;
}

int _progress(api.VoiceTranscriptStatus status) => switch (status) {
  api.VoiceTranscriptStatus.pending => 0,
  api.VoiceTranscriptStatus.failed => 1,
  api.VoiceTranscriptStatus.ready => 2,
};
