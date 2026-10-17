// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In-channel search: whether the field is open, and the last query's hits.
///
/// This was `ChannelScreen`'s own [State] until the compact layout needed the
/// same search from its app bar, which `HomeShell` builds above that screen
/// and so cannot reach into it. One controller per channel, so switching
/// channels can neither carry a query across nor show one channel's hits
/// under another channel's name.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/message_search.dart';

/// Hits come straight from the server (`api.Message`), never the local store's
/// own `Message`: a search result was not necessarily ever written locally.
///
/// [query] is the last query actually submitted, null once cleared. That is a
/// different thing from [results] being null, which also happens mid-request
/// and on a failure, neither of which is "no search running". [failed] is
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

class ChannelSearchController extends StateNotifier<ChannelSearchState> {
  ChannelSearchController(this._ref, this._channelId)
    : super(const ChannelSearchState());

  final Ref _ref;
  final String _channelId;

  /// Closing discards the query with it: a reopened field starts empty, so
  /// nothing can show hits for a search the user cannot see the terms of.
  void toggle() {
    state = state.open
        ? const ChannelSearchState()
        : const ChannelSearchState(open: true);
  }

  Future<void> run(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      state = const ChannelSearchState(open: true);
      return;
    }
    state = ChannelSearchState(open: true, query: trimmed, loading: true);
    final result = await searchChannelMessages(_ref.read, _channelId, trimmed);
    if (!mounted) return;
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
}

final channelSearchProvider = StateNotifierProvider.autoDispose
    .family<ChannelSearchController, ChannelSearchState, String>(
      (ref, channelId) => ChannelSearchController(ref, channelId),
    );
