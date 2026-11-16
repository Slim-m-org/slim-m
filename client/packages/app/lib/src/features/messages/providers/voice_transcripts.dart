// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice message transcripts that arrived live, by attachment id. A fetched
/// message carries its transcript itself; this only holds what a frame
/// delivered after the message was read, and wins over it unless the message
/// has since moved further along. Neither shows while the Space has them off.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/server_info.dart';

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

/// Whether the Space shows voice message transcripts, from `/version`; true
/// until it loads, so a Space that has them on never shows them late.
final voiceTranscriptsShownProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(
    serverInfoProvider.select(
      (info) => info.valueOrNull?.transcribeVoiceMessages ?? true,
    ),
  ),
);

/// The transcript a voice message shows: none while the Space has them off,
/// else the [live] frame unless the message itself has moved further along.
api.VoiceTranscript? shownVoiceTranscript(
  api.Attachment attachment,
  api.VoiceTranscript? live, {
  required bool spaceShows,
}) {
  if (!spaceShows) return null;
  final fetched = attachment.transcript;
  if (live == null) return fetched;
  if (fetched == null) return live;
  return _progress(fetched.status) > _progress(live.status) ? fetched : live;
}

/// What a voice message was heard saying, or null until there are words.
String? voiceTranscriptWords(
  api.Attachment attachment,
  api.VoiceTranscript? live, {
  required bool spaceShows,
}) {
  final shown = shownVoiceTranscript(attachment, live, spaceShows: spaceShows);
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
