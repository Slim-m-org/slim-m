// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The moderation-history feed, one page at a time: `GET /reports/history`
/// merges resolved reports with `moderation_audit_log` entries into one
/// newest-first feed, backing the History tab beside the open-reports queue
/// (see `reports_controller.dart` for that sibling and its own cursor).
///
/// Refreshes from the top on a live `reports.changed` event rather than
/// patching in place: the feed merges two sources this client cannot splice
/// incrementally, so a fresh first page is the same trade `PinsController`
/// makes for a pin event.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'live_events.dart';
import 'providers.dart';

/// How many history items to ask for at a time. Matches [reportsPageSize]'s
/// own reasoning: under the server's clamp, and enough that a small
/// deployment rarely sees a second page.
const int moderationHistoryPageSize = 50;

class ModerationHistoryState {
  const ModerationHistoryState({
    this.items = const [],
    this.loading = true,
    this.error,
    this.more = false,
  });

  final List<api.ModerationHistoryItem> items;
  final bool loading;

  /// The last failure, kept beside [items] rather than instead of them: a
  /// failed "load more" must not throw away the pages already on screen.
  final String? error;

  /// Whether the last page came back full, which is the only thing that says
  /// more may follow.
  final bool more;
}

class ModerationHistoryController
    extends StateNotifier<ModerationHistoryState> {
  ModerationHistoryController(this._ref)
    : super(const ModerationHistoryState()) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event is api.ReportsChanged) unawaited(refresh());
    });
    unawaited(refresh());
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;

  /// Bumped by every call that starts a load, so a response that arrives
  /// after a newer one was started is dropped instead of overwriting it.
  int _generation = 0;

  /// Starts the feed again from the top, keeping what is on screen until the
  /// first page lands.
  Future<void> refresh() async {
    state = ModerationHistoryState(
      items: state.items,
      loading: true,
      more: state.more,
    );
    await _load(after: null, onto: const []);
  }

  /// Asks for the page after the last item already held.
  Future<void> loadMore() async {
    if (state.loading || !state.more || state.items.isEmpty) return;
    state = ModerationHistoryState(
      items: state.items,
      loading: true,
      more: true,
    );
    final last = state.items.last;
    await _load(after: last, onto: state.items);
  }

  Future<void> _load({
    required api.ModerationHistoryItem? after,
    required List<api.ModerationHistoryItem> onto,
  }) async {
    final generation = ++_generation;
    final more = state.more;
    final held = state.items;
    try {
      final page = await _ref
          .read(apiProvider)
          .moderationHistory(
            after: after?.eventTime,
            afterKind: after?.cursorKind,
            afterId: after?.id,
            limit: moderationHistoryPageSize,
          );
      if (!mounted || generation != _generation) return;
      state = ModerationHistoryState(
        items: [...onto, ...page],
        loading: false,
        more: page.length >= moderationHistoryPageSize,
      );
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      state = ModerationHistoryState(
        items: after == null ? held : onto,
        loading: false,
        error: e is api.ApiException ? e.message : 'Could not read the feed.',
        more: more,
      );
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final moderationHistoryControllerProvider =
    StateNotifierProvider.autoDispose<
      ModerationHistoryController,
      ModerationHistoryState
    >((ref) => ModerationHistoryController(ref));
