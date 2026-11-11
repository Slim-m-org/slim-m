// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call's transcript for the idle voice pane (decision 0113): the lines read
/// a page at a time, read again when the server says it started or ended, and
/// the one delete.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

const transcriptPageSize = 50;

/// The most pages one jump to a line reads, so a bad seq cannot loop.
const _maxJumpPages = 40;

class CallTranscriptModel {
  const CallTranscriptModel({
    this.lines = const [],
    this.hasMore = false,
    this.loaded = false,
    this.busy = false,
    this.ongoing = false,
    this.deleted = false,
    this.error,
  });

  final List<api.TranscriptLine> lines;

  /// Another page follows the last loaded line.
  final bool hasMore;

  /// The first page has arrived, or failed.
  final bool loaded;
  final bool busy;
  final bool ongoing;
  final bool deleted;
  final String? error;

  CallTranscriptModel copyWith({
    List<api.TranscriptLine>? lines,
    bool? hasMore,
    bool? loaded,
    bool? busy,
    bool? ongoing,
    bool? deleted,
    String? error,
    bool clearError = false,
  }) => CallTranscriptModel(
    lines: lines ?? this.lines,
    hasMore: hasMore ?? this.hasMore,
    loaded: loaded ?? this.loaded,
    busy: busy ?? this.busy,
    ongoing: ongoing ?? this.ongoing,
    deleted: deleted ?? this.deleted,
    error: clearError ? null : error ?? this.error,
  );
}

class CallTranscriptController
    extends AutoDisposeFamilyNotifier<CallTranscriptModel, String> {
  late String transcriptId;
  bool _disposed = false;

  api.SlimmApi get _api => ref.read(apiProvider);

  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    final events = ref.read(liveEventsProvider).listen((event) {
      if (event is api.CallTranscriptChanged && event.transcriptId == arg) {
        unawaited(loadMore());
      }
    });
    ref.onDispose(() {
      _disposed = true;
      unawaited(events.cancel());
    });
    unawaited(Future<void>.microtask(loadMore));
    return const CallTranscriptModel();
  }

  /// Reads the page after the last loaded line, or the first page.
  Future<void> loadMore() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final after = state.lines.isEmpty ? null : state.lines.last.seq;
      final page = await _api.callTranscript(
        transcriptId,
        afterSeq: after,
        limit: transcriptPageSize,
      );
      if (_disposed) return;
      state = state.copyWith(
        lines: [...state.lines, ...page.lines],
        hasMore: page.nextAfterSeq != null,
        ongoing: page.ongoing,
        loaded: true,
        busy: false,
      );
    } on api.ApiException catch (error, stack) {
      if (_disposed) return;
      state = state.copyWith(
        busy: false,
        loaded: true,
        error: reportFailureSentence(
          api.LogTag.voice,
          'read the transcript',
          error,
          stack,
        ),
      );
    }
  }

  /// Reads pages until [seq] is loaded, for a jump from search.
  Future<void> loadThrough(int seq) async {
    for (var i = 0; i < _maxJumpPages; i++) {
      final lines = state.lines;
      final covered = lines.isNotEmpty && lines.last.seq >= seq;
      if (covered || (state.loaded && !state.hasMore) || state.error != null) {
        return;
      }
      await loadMore();
      if (_disposed) return;
    }
  }

  Future<bool> delete() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _api.deleteCallTranscript(transcriptId);
      if (_disposed) return true;
      state = state.copyWith(busy: false, deleted: true);
      return true;
    } on api.ApiException catch (error, stack) {
      if (_disposed) return false;
      state = state.copyWith(
        busy: false,
        error: reportFailureSentence(
          api.LogTag.voice,
          'delete the transcript',
          error,
          stack,
        ),
      );
      return false;
    }
  }
}

final callTranscriptProvider = NotifierProvider.autoDispose
    .family<CallTranscriptController, CallTranscriptModel, String>(
      CallTranscriptController.new,
    );

/// A line a search hit asked the pane to show, until the pane has scrolled to it.
typedef TranscriptFocus = ({String channelId, String transcriptId, int seq});

final transcriptFocusProvider = StateProvider<TranscriptFocus?>((ref) => null);
