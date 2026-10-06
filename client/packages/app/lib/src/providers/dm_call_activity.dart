// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether each DM channel currently has a call in progress, shared across
/// every [DmRow] rather than one poller per row.
///
/// `voiceRosterProvider` (`voice_roster.dart`) is the right shape for a
/// voice channel: a rail carries few of them, each one is a channel somebody
/// actually expects a live roster on, and its own 15-second
/// `Timer.periodic` is legitimate. `DirectMessagesSection` mounts every DM
/// row at once, so giving each its own independent poller multiplies with
/// the DM list, and firing them all on mount bursts the write-class rate
/// budget (`ratelimit.rs`'s burst of 30) the instant the rail renders,
/// starving a message send sharing the same bucket in the same window.
///
/// This controller polls nothing on a timer at all. `Event::VoiceActivityChanged`
/// (`voice.activity`) exists precisely so a call announces itself - a first
/// heartbeat (a join) or a real hangup - so a channel's state is learned
/// once, the first time a row asks about it, and again only when a live
/// event names that channel. Learning many channels at once (the rail's
/// first render) is queued through a small bounded number of concurrent
/// fetches rather than firing them all at once, which is what turns "every
/// DM row mounts simultaneously" into a controlled trickle instead of a
/// burst.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'live_events.dart';
import 'providers.dart';

/// How many roster lookups may be in flight at once while catching up on a
/// freshly mounted DM list. Bounded well under the write-class rate
/// budget's burst (30, `ratelimit.rs`) so populating even a large DM list
/// never starves a message send sharing the same bucket.
const dmCallActivityMaxConcurrentFetches = 4;

class DmCallActivityController extends StateNotifier<Map<String, bool>> {
  DmCallActivityController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event case api.VoiceActivityChanged(channelId: final id)) {
        if (_tracked.contains(id)) _enqueue(id);
      }
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;

  /// Every channel this session has ever asked about, so a repeat call from
  /// a rebuilding row costs a set lookup rather than a second fetch.
  final _tracked = <String>{};
  final _queue = Queue<String>();
  int _inFlight = 0;

  /// Learns [channelId]'s current call state if not already known or
  /// already queued. Safe to call from every row's build: idempotent past
  /// the first call for a given id, and queued rather than started
  /// immediately so many rows asking at once become a bounded trickle of
  /// requests instead of one each, all at once.
  void ensureTracked(String channelId) {
    if (!_tracked.add(channelId)) return;
    _enqueue(channelId);
  }

  void _enqueue(String channelId) {
    _queue.add(channelId);
    _pump();
  }

  void _pump() {
    while (_inFlight < dmCallActivityMaxConcurrentFetches &&
        _queue.isNotEmpty) {
      final channelId = _queue.removeFirst();
      _inFlight++;
      unawaited(
        _fetch(channelId).whenComplete(() {
          _inFlight--;
          _pump();
        }),
      );
    }
  }

  Future<void> _fetch(String channelId) async {
    try {
      final client = _ref.read(apiProvider);
      final roster = await client.voiceRoster(channelId);
      final selfId = client.session.tokens?.userId;
      final inCall = roster.any((p) => p.userId != selfId);
      if (mounted) state = {...state, channelId: inCall};
    } on api.NotConfiguredException {
      // No voice on this deployment; never fires again for this channel.
    } on api.ApiException {
      // Untracked again, so the next row that asks retries; waiting on a live event would leave a call already in progress unlit.
      _tracked.remove(channelId);
    }
  }

  /// Forgets every cached state and asks again about each tracked channel,
  /// for a session that may have missed a [api.VoiceActivityChanged] frame
  /// while disconnected: [SyncController.start] (`sync_controller.dart`)
  /// calls this on every (re)connect. There is no cursor to catch up from, and
  /// a row that already reads false never rebuilds to ask for itself.
  void clear() {
    _queue
      ..clear()
      ..addAll(_tracked);
    if (mounted) state = const {};
    _pump();
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Deliberately not `autoDispose`: a session that navigates away from the
/// rail and back must not re-burst every DM channel it already learned.
final dmCallActivityProvider =
    StateNotifierProvider<DmCallActivityController, Map<String, bool>>(
      (ref) => DmCallActivityController(ref),
    );
