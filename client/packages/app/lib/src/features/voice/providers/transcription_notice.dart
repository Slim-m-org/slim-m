// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-time `always` transcription notice's two calls (decision 0113), so
/// the join flow never talks to REST itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

class TranscriptionNoticeActions {
  const TranscriptionNoticeActions(this._api);

  final api.SlimmApi _api;

  /// Whether the member still owes the notice. A notice that cannot be read
  /// lets the join through; the in-call banner still says the call is transcribed.
  Future<bool> isDue() async {
    try {
      return (await _api.transcriptionNotice()).due;
    } on api.ApiException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'Could not check the transcription notice',
        error,
        stack,
      );
      return false;
    }
  }

  /// Records the acknowledgement; a failure only means it asks again next time.
  Future<void> acknowledge() async {
    try {
      await _api.ackTranscriptionNotice();
    } on api.ApiException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'Could not record the transcription notice',
        error,
        stack,
      );
    }
  }
}

final transcriptionNoticeActionsProvider = Provider<TranscriptionNoticeActions>(
  (ref) => TranscriptionNoticeActions(ref.watch(apiProvider)),
);
