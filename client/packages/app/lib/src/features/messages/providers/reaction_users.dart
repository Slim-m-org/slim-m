// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who left one reaction on one message, paged from the server.
///
/// The list arrives already filtered for this viewer, exactly as the tally is,
/// so nothing here filters again. It is dropped when nobody is looking: a
/// stale list of names is worse than a fresh request.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

typedef ReactionUsersKey = ({String messageId, String emoji});

/// [userIds] is null until the first page lands, which is how "still loading"
/// differs from an empty list.
class ReactionUsersState {
  const ReactionUsersState({
    this.userIds,
    this.nextCursor,
    this.loadingMore = false,
    this.failed = false,
  });

  final List<String>? userIds;
  final String? nextCursor;
  final bool loadingMore;

  /// The last request failed. The names already loaded stay on screen.
  final bool failed;

  bool get hasMore => nextCursor != null;
}

class ReactionUsersController extends StateNotifier<ReactionUsersState> {
  ReactionUsersController(this._ref, this._key)
    : super(const ReactionUsersState()) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event is api.ReactionsChanged && event.messageId == _key.messageId) {
        unawaited(refresh());
      }
    });
    unawaited(refresh());
  }

  final Ref _ref;
  final ReactionUsersKey _key;
  late final StreamSubscription<api.ServerEvent> _sub;

  // A refresh that lands after a newer one began must not overwrite it.
  int _generation = 0;

  Future<void> refresh() async {
    final generation = ++_generation;
    try {
      final page = await _fetch(null);
      if (!mounted || generation != _generation) return;
      state = ReactionUsersState(
        userIds: page.userIds,
        nextCursor: page.nextCursor,
      );
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'refresh who reacted', error, stack);
      if (!mounted || generation != _generation) return;
      state = ReactionUsersState(
        userIds: state.userIds,
        nextCursor: state.nextCursor,
        failed: true,
      );
    }
  }

  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    final loaded = state.userIds;
    if (cursor == null || loaded == null || state.loadingMore) return;
    final generation = _generation;
    state = ReactionUsersState(
      userIds: loaded,
      nextCursor: cursor,
      loadingMore: true,
    );
    try {
      final page = await _fetch(cursor);
      if (!mounted || generation != _generation) return;
      state = ReactionUsersState(
        userIds: [...loaded, ...page.userIds],
        nextCursor: page.nextCursor,
      );
    } on api.ApiException catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'load more people who reacted',
        error,
        stack,
      );
      if (!mounted || generation != _generation) return;
      state = ReactionUsersState(
        userIds: loaded,
        nextCursor: cursor,
        failed: true,
      );
    }
  }

  Future<api.ReactionUsersPage> _fetch(String? after) => _ref
      .read(apiProvider)
      .listReactionUsers(
        messageId: _key.messageId,
        emoji: _key.emoji,
        after: after,
      );

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final reactionUsersProvider = StateNotifierProvider.autoDispose
    .family<ReactionUsersController, ReactionUsersState, ReactionUsersKey>(
      (ref, key) => ReactionUsersController(ref, key),
    );
