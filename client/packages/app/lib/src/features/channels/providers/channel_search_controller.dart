// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In-channel search: whether the field is open, and the last query's hits.
///
/// This was `ChannelScreen`'s own [State] until the compact layout needed the
/// same search from its app bar, which `HomeShell` builds above that screen
/// and so cannot reach into it. One controller per channel, so switching
/// channels can neither carry a query across nor show one channel's hits
/// under another channel's name.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../messages/providers/message_search.dart';

/// Hits come straight from the server (`api.Message`), never the local store's
/// own `Message`: a search result was not necessarily ever written locally.
///
/// [query] is the last query actually submitted, null once cleared. That is a
/// different thing from [results] being null, which also happens before the
/// first reply and on a failure, neither of which is "no search running". While
/// a newer query [loading], [results] still holds the previous query's hits. [failed] is
/// likewise kept apart from an empty [results], so "the request failed" never
/// renders identically to "the request came back with nothing".
class ChannelSearchState {
  const ChannelSearchState({
    this.open = false,
    this.query,
    this.results,
    this.loading = false,
    this.failed = false,
    this.forbidden = false,
  });

  final bool open;
  final String? query;
  final List<api.Message>? results;
  final bool loading;
  final bool failed;

  /// True when the failure was a 403. Not transient: the same query will fail
  /// again until the caller's permissions change, so the results panel offers
  /// no retry for it.
  final bool forbidden;
}

/// How long the field must sit still before a query is sent.
const channelSearchDebounce = Duration(milliseconds: 250);

class ChannelSearchController extends StateNotifier<ChannelSearchState> {
  ChannelSearchController(this._ref, this._channelId)
    : super(const ChannelSearchState());

  final Ref _ref;
  final String _channelId;
  Timer? _debounce;

  /// Bumped by every run, clear and close, so only the newest request may write.
  int _request = 0;

  /// Closing discards the query with it: a reopened field starts empty, so
  /// nothing can show hits for a search the user cannot see the terms of.
  void toggle() {
    _supersede();
    state = state.open
        ? const ChannelSearchState()
        : const ChannelSearchState(open: true);
  }

  /// What typing in the field calls: waits for a pause, then [run]s.
  void queryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(channelSearchDebounce, () => unawaited(run(query)));
  }

  /// Hits already on screen stay up while a newer query loads, so typing does
  /// not blink the list into a spinner on every pause.
  Future<void> run(String query) async {
    final request = _supersede();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      state = const ChannelSearchState(open: true);
      return;
    }
    state = ChannelSearchState(
      open: true,
      query: trimmed,
      results: state.results,
      loading: true,
    );
    final result = await searchChannelMessages(_ref.read, _channelId, trimmed);
    if (!mounted || request != _request) return;
    state = switch (result) {
      MessageSearchHits(:final messages) => ChannelSearchState(
        open: true,
        query: trimmed,
        results: messages,
      ),
      MessageSearchForbidden() => ChannelSearchState(
        open: true,
        query: trimmed,
        failed: true,
        forbidden: true,
      ),
      MessageSearchFailed() => ChannelSearchState(
        open: true,
        query: trimmed,
        failed: true,
      ),
    };
  }

  /// Drops a query still waiting to be sent and the reply to one in flight.
  int _supersede() {
    _debounce?.cancel();
    return ++_request;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final channelSearchProvider = StateNotifierProvider.autoDispose
    .family<ChannelSearchController, ChannelSearchState, String>(
      (ref, channelId) => ChannelSearchController(ref, channelId),
    );
