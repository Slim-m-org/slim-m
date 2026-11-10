// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug logs members sent, one page at a time: `GET /debug-logs`, newest
/// first, paged backward with `before` set to the oldest id held.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/providers.dart';

/// Under the server's clamp, and enough that a small space rarely needs two.
const int debugLogsPageSize = 50;

class DebugLogsState {
  const DebugLogsState({
    this.items = const [],
    this.loading = true,
    this.error,
    this.more = false,
  });

  final List<api.DebugLogEntry> items;
  final bool loading;

  /// A sentence to show, kept beside [items] so a failed "load more" keeps the
  /// pages on screen.
  final String? error;

  /// Whether the last page came back full, the only sign that more follows.
  final bool more;
}

class DebugLogsController extends AutoDisposeNotifier<DebugLogsState> {
  bool _disposed = false;

  @override
  DebugLogsState build() {
    ref.onDispose(() => _disposed = true);
    unawaited(Future.microtask(refresh));
    return const DebugLogsState();
  }

  /// A response that lands after a newer load started is dropped.
  int _generation = 0;

  Future<void> refresh() async {
    state = DebugLogsState(items: state.items, more: state.more);
    await _load(before: null, onto: const []);
  }

  /// Deletes [id] on the server, then drops it from the list.
  Future<void> delete(int id) async {
    await ref.read(apiProvider).deleteDebugLog(id);
    if (_disposed) return;
    state = DebugLogsState(
      items: [
        for (final e in state.items)
          if (e.id != id) e,
      ],
      loading: false,
      more: state.more,
    );
  }

  Future<void> loadMore() async {
    if (state.loading || !state.more || state.items.isEmpty) return;
    state = DebugLogsState(items: state.items, more: true);
    await _load(before: state.items.last.id, onto: state.items);
  }

  Future<void> _load({
    required int? before,
    required List<api.DebugLogEntry> onto,
  }) async {
    final generation = ++_generation;
    final held = state.items;
    final more = state.more;
    try {
      final page = await ref
          .read(apiProvider)
          .listDebugLogs(before: before, limit: debugLogsPageSize);
      if (_disposed || generation != _generation) return;
      state = DebugLogsState(
        items: [...onto, ...page],
        loading: false,
        more: page.length >= debugLogsPageSize,
      );
    } on Object catch (e, stack) {
      final sentence = reportFailureSentence(
        api.LogTag.ui,
        before == null ? 'load the debug logs' : 'load more debug logs',
        e,
        stack,
      );
      if (_disposed || generation != _generation) return;
      state = DebugLogsState(
        items: before == null ? held : onto,
        loading: false,
        error: sentence,
        more: more,
      );
    }
  }
}

final debugLogsControllerProvider =
    NotifierProvider.autoDispose<DebugLogsController, DebugLogsState>(
      DebugLogsController.new,
    );
