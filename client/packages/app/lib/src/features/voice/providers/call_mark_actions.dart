// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one mark action the Mark button, the in-window shortcut and the global
/// hotkey all use: mark the moment in the call this device is in, or say why
/// it could not. It needs only the call's channel and running transcript, so
/// it works with no dock row on screen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../ids.dart';
import '../../../providers/providers.dart';
import 'call_mark_chip.dart';
import 'call_transcript_marks.dart';
import 'live_call_transcript.dart';
import 'voice_flags.dart';

const notTranscribedNotice = 'This call is not transcribed';

class CallMarkActions {
  CallMarkActions(this._ref);

  final Ref _ref;

  /// Marks the moment, with [note] when given; a retry passes the same [id] so it is the same mark. Null once kept, else the
  /// sentence that says why not, which the chip also shows.
  Future<String?> mark({String? note, String? id}) async {
    final channelId = _ref.read(voiceFlagsProvider).channelId;
    if (channelId == null) return notTranscribedNotice;
    final chip = _ref.read(callMarkChipProvider(channelId).notifier);
    final transcriptId = _ref.read(liveCallTranscriptIdProvider(channelId));
    if (transcriptId == null) {
      chip.notice(notTranscribedNotice);
      return notTranscribedNotice;
    }
    try {
      final kept = await _ref
          .read(apiProvider)
          .putCallTranscriptMark(
            transcriptId,
            id ?? newCallMarkId(),
            note: note,
          );
      chip.shown(kept);
      if (_ref.exists(transcriptMarksProvider(transcriptId))) {
        _ref.read(transcriptMarksProvider(transcriptId).notifier).keep(kept);
      }
      return null;
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.voice, 'mark the moment', error, stack);
      final sentence = switch (error) {
        api.RateLimitedException() => 'Marked a moment ago',
        _ => describeApiFailure('mark the moment', error),
      };
      chip.notice(sentence);
      return sentence;
    }
  }
}

final callMarkActionsProvider = Provider<CallMarkActions>(CallMarkActions.new);
