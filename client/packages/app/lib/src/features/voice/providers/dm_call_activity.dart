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

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/rate_limit_retry.dart';

/// How many roster lookups may be in flight at once while catching up on a
/// freshly mounted DM list. Bounded well under the authed-read rate budget's
/// burst (40, `ratelimit/class.rs`) so populating even a large DM list never
/// starves the other reads sharing that bucket.
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

  /// Tracked channels whose last lookup failed, so the next row that asks retries.
  final _failed = <String>{};
  final _queue = Queue<String>();

  /// Channels with a lookup running, and whether a newer ask arrived meanwhile.
  /// One lookup per channel at a time keeps an older answer from landing last.
  final _running = <String, bool>{};

  /// Bumped by [clear], so a lookup from before it never lands after it.
  int _epoch = 0;

  /// Learns [channelId]'s current call state if not already known or
  /// already queued. Safe to call from every row's build: idempotent past
  /// the first call for a given id, and queued rather than started
  /// immediately so many rows asking at once become a bounded trickle of
  /// requests instead of one each, all at once.
  void ensureTracked(String channelId) {
    final retry = _failed.remove(channelId);
    if (!_tracked.add(channelId) && !retry) return;
    _enqueue(channelId);
  }

  void _enqueue(String channelId) {
    if (_running.containsKey(channelId)) {
      _running[channelId] = true;
      return;
    }
    if (_queue.contains(channelId)) return;
    _queue.add(channelId);
    _pump();
  }

  void _pump() {
    while (_running.length < dmCallActivityMaxConcurrentFetches &&
        _queue.isNotEmpty) {
      final channelId = _queue.removeFirst();
      _running[channelId] = false;
      final epoch = _epoch;
      unawaited(
        _fetch(channelId, epoch).whenComplete(() {
          if (epoch != _epoch) return;
          final askedAgain = _running.remove(channelId) ?? false;
          if (askedAgain) _enqueue(channelId);
          _pump();
        }),
      );
    }
  }

  /// Whether [channelId]'s running lookup still answers the latest ask.
  bool _isLatest(String channelId, int epoch) =>
      mounted && epoch == _epoch && _running[channelId] == false;

  Future<void> _fetch(String channelId, int epoch) async {
    try {
      final client = _ref.read(apiProvider);
      final roster = await retryWhenRateLimited(
        () => client.voiceRoster(channelId),
        wait: _ref.read(rateLimitWaitProvider),
      );
      final selfId = client.session.tokens?.userId;
      final inCall = roster.any((p) => p.userId != selfId);
      if (!_isLatest(channelId, epoch)) return;
      _failed.remove(channelId);
      state = {...state, channelId: inCall};
    } on api.NotConfiguredException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'This server has no voice; not checking this channel for calls again',
        error,
        stack,
      );
    } on api.ApiException catch (error, stack) {
      api.reportFailure(
        api.LogTag.voice,
        'check for a call in a direct message',
        error,
        stack,
      );
      // The last answer stays shown and live events still refetch; the next row that asks retries too.
      if (epoch == _epoch) _failed.add(channelId);
    }
  }

  /// Asks again about every tracked channel, keeping what is shown until each
  /// answers. `afterSyncLive` (`sync_live_refresh.dart`) calls this once the
  /// socket is subscribed: a [api.VoiceActivityChanged] frame missed while
  /// disconnected is never replayed, and a row that already reads false never
  /// rebuilds to ask for itself.
  void resync() {
    _failed.clear();
    _tracked.forEach(_enqueue);
  }

  /// Forgets every channel and its state, for a session that ended.
  void clear() {
    _epoch++;
    _tracked.clear();
    _failed.clear();
    _queue.clear();
    _running.clear();
    if (mounted) state = const {};
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
