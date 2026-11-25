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

  /// Whether the member may still owe the notice; a notice that cannot be read counts as owed, so nothing joins unannounced.
  Future<bool> isDue() async {
    try {
      return await dueNotice() != null;
    } on api.ApiException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'Could not check the transcription notice',
        error,
        stack,
      );
      return true;
    }
  }

  /// The notice while it is owed, else null; throws [api.ApiException] when it cannot be read.
  Future<api.TranscriptionNotice?> dueNotice() async {
    final notice = await _api.transcriptionNotice();
    return notice.due ? notice : null;
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
