// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks and notes on one call transcript: read once, kept current by the
/// `call.transcript_mark` frame while the call runs, and read again on a
/// reconnect, since a frame missed while offline never arrives.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

class TranscriptMarksModel {
  const TranscriptMarksModel({
    this.marks = const [],
    this.loaded = false,
    this.error,
  });

  /// Oldest first.
  final List<api.TranscriptMark> marks;
  final bool loaded;
  final String? error;

  /// The marks that point at line [seq].
  Iterable<api.TranscriptMark> onLine(int seq) =>
      marks.where((m) => m.lineSeq == seq);
}

class TranscriptMarksController
    extends AutoDisposeFamilyNotifier<TranscriptMarksModel, String> {
  late String transcriptId;
  bool _disposed = false;

  api.SlimmApi get _api => ref.read(apiProvider);

  @override
  TranscriptMarksModel build(String arg) {
    transcriptId = arg;
    final events = ref.read(liveEventsProvider).listen(_onEvent);
    ref.onDispose(() {
      _disposed = true;
      unawaited(events.cancel());
    });
    ref.listen(syncControllerProvider, (previous, next) {
      if (next == SyncStatus.live && previous != SyncStatus.live) {
        unawaited(load());
      }
    });
    unawaited(Future<void>.microtask(load));
    return const TranscriptMarksModel();
  }

  void _onEvent(api.ServerEvent event) {
    if (event case api.CallTranscriptMarkChanged(
      :final transcriptId,
      :final markId,
      :final mark,
    ) when transcriptId == this.transcriptId) {
      mark == null ? _drop(markId) : keep(mark);
    }
  }

  /// Adds or replaces [mark] in time order, for a frame or a mark this device just made.
  void keep(api.TranscriptMark mark) {
    final marks = [
      for (final held in state.marks)
        if (held.id != mark.id) held,
      mark,
    ]..sort((a, b) => a.at.compareTo(b.at));
    state = TranscriptMarksModel(marks: marks, loaded: state.loaded);
  }

  void _drop(String markId) {
    state = TranscriptMarksModel(
      marks: [
        for (final held in state.marks)
          if (held.id != markId) held,
      ],
      loaded: state.loaded,
    );
  }

  Future<void> load() async {
    try {
      final marks = await _api.callTranscriptMarks(transcriptId);
      if (_disposed) return;
      state = TranscriptMarksModel(marks: marks, loaded: true);
    } on api.ApiException catch (error, stack) {
      if (_disposed) return;
      state = TranscriptMarksModel(
        marks: state.marks,
        loaded: true,
        error: reportFailureSentence(
          api.LogTag.voice,
          'read the marks',
          error,
          stack,
        ),
      );
    }
  }

  /// Removes [markId]; the failure sentence when the server refused.
  Future<String?> delete(String markId) async {
    try {
      await _api.deleteCallTranscriptMark(transcriptId, markId);
      if (!_disposed) _drop(markId);
      return null;
    } on api.ApiException catch (error, stack) {
      return reportFailureSentence(
        api.LogTag.voice,
        'remove the mark',
        error,
        stack,
      );
    }
  }
}

final transcriptMarksProvider = NotifierProvider.autoDispose
    .family<TranscriptMarksController, TranscriptMarksModel, String>(
      TranscriptMarksController.new,
    );
