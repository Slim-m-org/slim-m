// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice message transcripts. A message carries its own; a live frame updates
/// the held message's attachment (see `MessageExtrasController`), and neither
/// shows while the Space has them off.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/server_info.dart';

/// Whether the Space shows voice message transcripts, from `/version`; true
/// until it loads, so a Space that has them on never shows them late.
final voiceTranscriptsShownProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(
    serverInfoProvider.select(
      (info) => info.valueOrNull?.transcribeVoiceMessages ?? true,
    ),
  ),
);

/// The transcript a voice message shows: none while the Space has them off.
api.VoiceTranscript? shownVoiceTranscript(
  api.Attachment attachment, {
  required bool spaceShows,
}) => spaceShows ? attachment.transcript : null;

/// What a voice message was heard saying, or null until there are words.
String? voiceTranscriptWords(
  api.Attachment attachment, {
  required bool spaceShows,
}) {
  final shown = shownVoiceTranscript(attachment, spaceShows: spaceShows);
  if (shown == null || shown.status != api.VoiceTranscriptStatus.ready) {
    return null;
  }
  return shown.text.isEmpty ? null : shown.text;
}

/// How far along [transcript] is, so a later stage is never undone by an
/// earlier one arriving late; none at all ranks lowest.
int voiceTranscriptProgress(api.VoiceTranscript? transcript) =>
    switch (transcript?.status) {
      null => -1,
      api.VoiceTranscriptStatus.pending => 0,
      api.VoiceTranscriptStatus.failed => 1,
      api.VoiceTranscriptStatus.ready => 2,
    };
