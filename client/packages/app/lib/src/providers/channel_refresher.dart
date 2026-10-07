// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the channel listing (and each channel's read marker) current,
/// deduplicating a concurrent refresh into the one already running.
///
/// Split out of `sync_controller.dart`: unlike catch-up and the live socket,
/// this never touches the connection's own state, so it is a seam that does
/// not disturb the reconnect logic around it.
library;

import 'dart:async';

import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

import 'dms.dart';
import 'rate_limit_retry.dart';

/// Refreshes both channel listings the server keeps apart, and hydrates
/// their read markers, deduplicating a concurrent caller into the refresh
/// already running rather than starting a second.
class ChannelRefresher {
  Future<void>? _inFlight;
  Completer<void>? _trailing;
  _Request? _trailingRequest;

  /// Refreshes both channel listings the server keeps apart: the
  /// deployment's own channels, and the caller's DM conversations (which
  /// `GET /channels` deliberately excludes). Both land in the same local
  /// channel table under the same shape, so everything downstream (the
  /// rail, sync cursors, read state) treats a DM exactly like any other
  /// channel once it is here. Also prunes any channel the server no longer
  /// lists, so one whose view was just revoked leaves the rail rather than
  /// sitting there until sign-out.
  ///
  /// Also replaces the local category list from its own `GET /categories`
  /// request - a separate route from `GET /channels`, since the wire is
  /// additive-only and folding the list into that response would have
  /// reshaped it - on its own store path ([MessageStore.replaceCategories])
  /// rather than folded into [MessageStore.replaceChannels]: a category is
  /// not a channel and never appears in that list, so pruning it there would
  /// wipe every category on the very first refresh. See docs/decisions/
  /// 0006-channel-categories.md.
  ///
  /// Also hydrates each channel's read marker from the server. `ScopeDelta`
  /// carries no read state, so `/sync` can never do this, and
  /// `MessageStore.clear()` wipes the local marker on every sign-out; without
  /// this, a reinstall or a second device shows every channel unread
  /// forever, however recently it was actually read elsewhere.
  /// [isCurrent] is checked immediately before every write, never only on
  /// entry. Three network round trips happen first, and a sign-out landing in
  /// any of those windows clears the store; without this the answer to a
  /// request made by the account signing out lands in the database afterwards
  /// and the next person on the device reads the previous account's channel
  /// list. The caller owns the definition of current, because only it knows
  /// what supersedes it.
  Future<void> refresh(
    SlimmApi api,
    MessageStore store, {
    required bool Function() isCurrent,
    RateLimitWait wait = sleepFor,
  }) async {
    // Three independent reads issued concurrently, then awaited together; Future.wait rethrows the first failure and consumes the rest, abandoning the write.
    final channelsFuture = api.listChannels();
    final categoriesFuture = api.listCategories();
    final dmsFuture = api.listDirectMessages();
    await Future.wait([channelsFuture, categoriesFuture, dmsFuture]);
    if (!isCurrent()) return;
    final channels = await channelsFuture;
    final categories = await categoriesFuture;
    final dms = await dmsFuture;
    final selfId = api.session.tokens?.userId;
    final all = [
      ...channels,
      ...dms.map((dm) => channelFromDm(dm, selfId: selfId)),
    ];
    await store.replaceChannels(all);
    if (!isCurrent()) return;
    await store.replaceCategories(categories);

    await _hydrateReadMarkers(api, store, isCurrent: isCurrent, wait: wait);
  }

  /// One `GET /read-states` for every channel, not one request per channel:
  /// each of those spends an `AuthedRead` token, and a deployment past about
  /// forty channels ran the bucket dry on the sign-in alone. Best-effort, as
  /// the per-channel reads were: a failure leaves every channel reading
  /// unread until the next refresh.
  Future<void> _hydrateReadMarkers(
    SlimmApi api,
    MessageStore store, {
    required bool Function() isCurrent,
    required RateLimitWait wait,
  }) async {
    final List<ChannelReadState> states;
    try {
      states = await retryWhenRateLimited(api.listReadStates, wait: wait);
    } on NotFoundException {
      await _hydratePerChannel(api, store, isCurrent: isCurrent);
      return;
    } on ApiException {
      return;
    }
    for (final read in states) {
      if (!isCurrent()) return;
      await store.setReadMarker(
        read.channelId,
        read.state.lastReadSeq,
        manuallyUnread: read.state.manuallyUnread,
      );
    }
  }

  /// A server that predates `GET /read-states` answers 404 to it, and only
  /// the per-channel route can hydrate its markers. One channel's failure
  /// must not stop the rest.
  Future<void> _hydratePerChannel(
    SlimmApi api,
    MessageStore store, {
    required bool Function() isCurrent,
  }) async {
    final channels = await store.allChannels();
    if (!isCurrent()) return;
    await Future.wait(
      channels.map((channel) async {
        try {
          final read = await api.readState(channel.id);
          if (!isCurrent()) return;
          await store.setReadMarker(
            channel.id,
            read.lastReadSeq,
            manuallyUnread: read.manuallyUnread,
          );
        } on ApiException {
          // Best-effort: the next refresh retries; until then it just reads as unread.
        }
      }),
    );
  }

  /// [refresh], but a concurrent caller joins the one already running
  /// instead of starting a second. For a caller that only needs the listing
  /// to be current by the time the run ends, such as a message in a channel
  /// not held yet.
  Future<void> refreshOnce(
    SlimmApi api,
    MessageStore store, {
    required bool Function() isCurrent,
  }) => _inFlight ?? _start(_Request(api, store, isCurrent));

  /// [refreshOnce] for a caller told that server state just changed. The
  /// running refresh may already have read the old state, so a caller
  /// arriving mid-run waits on one trailing run instead of joining it.
  Future<void> refreshAfterChange(
    SlimmApi api,
    MessageStore store, {
    required bool Function() isCurrent,
  }) {
    if (_inFlight == null) return _start(_Request(api, store, isCurrent));
    _trailingRequest = _Request(api, store, isCurrent);
    return (_trailing ??= Completer<void>()).future;
  }

  Future<void> _start(_Request request) {
    late final Future<void> run;
    run = refresh(request.api, request.store, isCurrent: request.isCurrent)
        .whenComplete(() {
          if (identical(_inFlight, run)) _inFlight = null;
          _startTrailing();
        });
    return _inFlight = run;
  }

  void _startTrailing() {
    final waiting = _trailing;
    final request = _trailingRequest;
    _trailing = null;
    _trailingRequest = null;
    if (waiting == null || request == null || _inFlight != null) {
      waiting?.complete();
      return;
    }
    _start(request).then(waiting.complete, onError: waiting.completeError);
  }

  /// Stops a later caller joining a refresh started before it, without
  /// cancelling that refresh: its own [isCurrent] is what stops its writes.
  /// Sharing across that boundary would hand a caller from the new session a
  /// future guarded by the old one's predicate, which aborts, so the work it
  /// asked for silently never happens.
  void discardInFlight() {
    _inFlight = null;
    _trailingRequest = null;
    _trailing?.complete();
    _trailing = null;
  }
}

class _Request {
  const _Request(this.api, this.store, this.isCurrent);
  final SlimmApi api;
  final MessageStore store;
  final bool Function() isCurrent;
}
