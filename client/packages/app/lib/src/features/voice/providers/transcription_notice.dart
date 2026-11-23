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
  /// lets the join through; the call header's transcript mark still says the call is transcribed.
  Future<bool> isDue() async => await dueNotice() != null;

  /// The notice while it is owed, else null; [isDue] says why a failed read is null.
  Future<api.TranscriptionNotice?> dueNotice() async {
    try {
      final notice = await _api.transcriptionNotice();
      return notice.due ? notice : null;
    } on api.ApiException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'Could not check the transcription notice',
        error,
        stack,
      );
      return null;
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
