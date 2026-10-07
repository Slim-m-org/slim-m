// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel's pinned messages: fetched once per channel, refreshed whenever
/// a live `message.pinned`/`message.unpinned` event says the set changed.
///
/// Kept as the full list rather than just a count: the header pill only
/// needs the length, but the same state also backs the sheet that lists
/// them, and a second fetch there would just be the same request twice.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'blocks_controller.dart';
import 'live_events.dart';
import 'providers.dart';

/// A channel's pinned messages, newest pin first (matching the endpoint), plus
/// whether the most recent fetch failed.
///
/// [pinned] is null only until the first fetch lands, distinct from an empty
/// list: the header pill shows a dash for the former and "0" for the latter.
/// A failed refresh leaves [pinned] exactly as it was (never blanks a pill
/// already showing a real number) but still sets [failed], which is what lets
/// the sheet tell "still loading" apart from "loading did not work" instead of
/// spinning forever on a request that already came back.
class PinsState {
  const PinsState({this.pinned, this.failed = false, this.forbidden = false});

  final List<api.PinnedMessage>? pinned;
  final bool failed;

  /// True when the failure was a 403: not a channel this account can see
  /// pins in right now, and retrying the same request will not change that.
  final bool forbidden;
}

/// Keeps [PinsState] current for one channel.
///
/// A pin event triggers a full refetch rather than an incremental patch: the
/// live frame carries only the one message id, and the list is small enough
/// (self-hosted friend groups, not a public forum) that re-fetching it whole is
/// simpler than reconstructing pin order from a delta.
class PinsController extends StateNotifier<PinsState> {
  PinsController(this._ref, this._channelId) : super(const PinsState()) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      final matches = switch (event) {
        api.MessagePinned(:final channelId) => channelId == _channelId,
        api.MessageUnpinned(:final channelId) => channelId == _channelId,
        _ => false,
      };
      if (matches) unawaited(refresh());
    });
    unawaited(refresh());
  }

  final Ref _ref;
  final String _channelId;
  late final StreamSubscription<api.ServerEvent> _sub;

  /// Bumped by every refresh, so an older response that lands after a newer
  /// one was started is dropped instead of overwriting it.
  int _generation = 0;

  Future<void> refresh() async {
    final generation = ++_generation;
    // Guarded after every await, because this is an autoDispose family fired
    // unawaited from the constructor and the live-event listener: switching
    // channels mid-fetch disposes this instance, and assigning or even reading
    // `state` afterwards throws an unhandled StateError. Matches
    // channel_search_controller, which guards the identical pattern.
    try {
      final all = await _ref.read(apiProvider).listPinnedMessages(_channelId);
      if (!mounted || generation != _generation) return;
      // Somebody else's pin must not be a way around the viewer's own filter.
      final blocks = _ref.read(blocksProvider);
      final pinned = all
          .where((pin) => !blocks.contains(pin.message.authorId))
          .toList(growable: false);
      state = PinsState(pinned: pinned);
    } on api.ForbiddenException {
      if (!mounted || generation != _generation) return;
      state = PinsState(pinned: state.pinned, failed: true, forbidden: true);
    } on api.ApiException {
      if (!mounted || generation != _generation) return;
      state = PinsState(pinned: state.pinned, failed: true);
    }
  }

  /// Pins a message, or leaves the timestamp alone if it already was one
  /// (idempotent server-side).
  Future<void> pin(String messageId) async {
    await _ref
        .read(apiProvider)
        .pinMessage(channelId: _channelId, messageId: messageId);
    await refresh();
  }

  Future<void> unpin(String messageId) async {
    await _ref
        .read(apiProvider)
        .unpinMessage(channelId: _channelId, messageId: messageId);
    await refresh();
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final pinsControllerProvider = StateNotifierProvider.autoDispose
    .family<PinsController, PinsState, String>(
      (ref, channelId) => PinsController(ref, channelId),
    );
