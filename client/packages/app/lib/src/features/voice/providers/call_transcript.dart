// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call's transcript (decision 0113): the lines read a page at a time, live
/// lines appended in `seq` order with a read to fill any gap, and the one delete.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

const transcriptPageSize = 50;

/// A running call's page, so a pane opened late in a long call reaches its end in few reads.
const liveTranscriptPageSize = 500;

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

  /// Live lines that came in while a page was being read, applied once it lands.
  final _held = <api.TranscriptLine>[];

  /// A read was asked for while one ran, so another follows it.
  bool _again = false;

  /// The last seq a gap read started after; a gap still there after it is a line REST no longer has.
  int? _gapReadAfter;

  api.SlimmApi get _api => ref.read(apiProvider);

  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    final events = ref.read(liveEventsProvider).listen(_onEvent);
    ref.onDispose(() {
      _disposed = true;
      unawaited(events.cancel());
    });
    // Lines sent while the socket was down never arrive; read what follows the last one held.
    ref.listen(syncControllerProvider, (previous, next) {
      if (next == SyncStatus.live && previous != SyncStatus.live) {
        if (state.loaded && !state.hasMore) unawaited(loadMore());
      }
    });
    unawaited(Future<void>.microtask(loadMore));
    return const CallTranscriptModel();
  }

  void _onEvent(api.ServerEvent event) {
    switch (event) {
      case api.CallTranscriptChanged(:final transcriptId)
          when transcriptId == this.transcriptId:
        unawaited(loadMore());
      case api.CallTranscriptLineAdded(:final transcriptId, :final line)
          when transcriptId == this.transcriptId:
        if (state.busy) {
          _held.add(line);
        } else {
          _apply(line);
        }
      default:
    }
  }

  /// Appends [line] when it is the next one; a gap reads the missing lines instead.
  void _apply(api.TranscriptLine line) {
    if (!state.loaded) return;
    if (state.hasMore || state.error != null) {
      _held.add(line);
      unawaited(loadMore());
      return;
    }
    final last = state.lines.isEmpty ? 0 : state.lines.last.seq;
    if (line.seq <= last) return;
    if (line.seq == last + 1 || _gapReadAfter == last) {
      state = state.copyWith(lines: [...state.lines, line]);
    } else {
      _gapReadAfter = last;
      _held.add(line);
      unawaited(loadMore());
    }
  }

  void _applyHeld() {
    final held = [..._held]..sort((a, b) => a.seq.compareTo(b.seq));
    _held.clear();
    for (final line in held) {
      if (state.busy) {
        _held.add(line);
      } else {
        _apply(line);
      }
    }
  }

  /// Reads the page after the last loaded line, or the first page.
  Future<void> loadMore() async {
    if (state.busy) {
      _again = true;
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final after = state.lines.isEmpty ? null : state.lines.last.seq;
      final page = await _api.callTranscript(
        transcriptId,
        afterSeq: after,
        limit: state.ongoing ? liveTranscriptPageSize : transcriptPageSize,
      );
      if (_disposed) return;
      final last = state.lines.isEmpty ? 0 : state.lines.last.seq;
      state = state.copyWith(
        lines: [
          ...state.lines,
          for (final line in page.lines)
            if (line.seq > last) line,
        ],
        hasMore: page.nextAfterSeq != null,
        ongoing: page.ongoing,
        loaded: true,
        busy: false,
      );
      _applyHeld();
      // A running call is read to its end, so a live line has a last line to follow.
      if (page.ongoing && page.nextAfterSeq != null) _again = true;
      if (_again && !state.busy) {
        _again = false;
        unawaited(loadMore());
      }
    } on api.ApiException catch (error, stack) {
      if (_disposed) return;
      _held.clear();
      _again = false;
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
      _applyHeld();
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
