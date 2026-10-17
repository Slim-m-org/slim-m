// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the room is in what it is watching, read from REST and kept current
/// by the bot's `watch.tick` frames.
///
/// Every sample carries the server's clock, so a REST read and a tick are
/// ordered against each other rather than by which arrived last, and a room
/// is over once the server's own lifetime for a session has passed without a
/// sample. A tick from another bot, another item or a higher epoch is the
/// cue to re-read the session rather than trust a frame that carries no
/// title. See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

/// The app's wall clock, replaceable so a test can hold time still.
final watchClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// One sample of the room's position, timed on the server's clock.
class WatchRoom {
  const WatchRoom({
    required this.botUserId,
    required this.itemId,
    required this.title,
    required this.playing,
    required this.position,
    required this.sampledAtMs,
    required this.epoch,
    required this.ttl,
    required this.clockOffset,
    this.duration,
  });

  final String botUserId;
  final String itemId;
  final String title;
  final bool playing;
  final Duration? duration;

  /// Where the room was at [sampledAtMs].
  final Duration position;

  /// The server clock at the sample; what a newer sample is judged against.
  final int sampledAtMs;
  final int epoch;

  /// How long after a sample the server still calls the session live.
  final Duration ttl;

  /// The server's clock minus this device's, from the last REST read.
  final Duration clockOffset;

  factory WatchRoom.fromSession(api.WatchSession s, DateTime now) => WatchRoom(
    botUserId: s.botUserId,
    itemId: s.itemId,
    title: s.title,
    playing: s.playing,
    position: Duration(milliseconds: s.positionMs),
    sampledAtMs: s.sampledAtMs,
    epoch: s.epoch,
    ttl: Duration(milliseconds: s.ttlMs),
    clockOffset: Duration(
      milliseconds: s.serverTimeMs - now.millisecondsSinceEpoch,
    ),
    duration: s.durationMs == null
        ? null
        : Duration(milliseconds: s.durationMs!),
  );

  /// Whether [tick] continues this same session, so it can update it in place.
  bool isSameSession(api.WatchTick tick) =>
      tick.botUserId == botUserId &&
      tick.itemId == itemId &&
      tick.epoch == epoch;

  WatchRoom afterTick(api.WatchTick tick) => WatchRoom(
    botUserId: botUserId,
    itemId: itemId,
    title: title,
    playing: tick.playing,
    position: Duration(milliseconds: tick.positionMs),
    sampledAtMs: tick.sampledAtMs,
    epoch: epoch,
    ttl: ttl,
    clockOffset: clockOffset,
    duration: duration,
  );

  /// This device's time at the sample.
  DateTime get _sampledAt =>
      DateTime.fromMillisecondsSinceEpoch(sampledAtMs).subtract(clockOffset);

  Duration positionAt(DateTime now) {
    final elapsed = playing ? now.difference(_sampledAt) : Duration.zero;
    final at = position + (elapsed.isNegative ? Duration.zero : elapsed);
    final end = duration;
    return end != null && at > end ? end : at;
  }

  bool isStale(DateTime now) => now.difference(_sampledAt) > ttl;

  /// Whether [other], read later, is at least as new as this sample.
  bool isNotNewerThan(api.WatchSession other) =>
      other.epoch > epoch ||
      (other.epoch == epoch && other.sampledAtMs >= sampledAtMs);
}

/// The room's session for [channelId], or null while nothing is playing.
///
/// A failed read surfaces as the provider's error rather than being
/// swallowed; the bar keeps the last good sample on screen meanwhile.
final watchRoomProvider = StreamProvider.autoDispose.family<WatchRoom?, String>(
  (ref, channelId) {
    final feed = _WatchRoomFeed(
      client: ref.watch(apiProvider),
      clock: ref.watch(watchClockProvider),
      channelId: channelId,
    );
    final sub = ref.read(liveEventsProvider).listen((event) {
      if (event is api.WatchTick && event.channelId == channelId) {
        feed.onTick(event);
      }
    });
    ref.onDispose(() {
      unawaited(sub.cancel());
      unawaited(feed.close());
    });
    unawaited(feed.load());
    return feed.stream;
  },
);

class _WatchRoomFeed {
  _WatchRoomFeed({
    required this.client,
    required this.clock,
    required this.channelId,
  });

  final api.SlimmApi client;
  final DateTime Function() clock;
  final String channelId;
  final StreamController<WatchRoom?> _controller =
      StreamController<WatchRoom?>();
  WatchRoom? _current;
  ({String bot, int epoch})? _ended;
  int _applied = 0;

  Stream<WatchRoom?> get stream => _controller.stream;

  Future<void> close() => _controller.close();

  void _emit(WatchRoom? room) {
    _current = room;
    _applied++;
    if (!_controller.isClosed) _controller.add(room);
  }

  bool _supersedes(api.WatchSession s) {
    final over = _ended;
    if (over != null && s.botUserId == over.bot && s.epoch <= over.epoch) {
      return false;
    }
    final room = _current;
    return room == null || room.isNotNewerThan(s);
  }

  Future<void> load() async {
    final appliedBefore = _applied;
    final api.WatchSession? session;
    try {
      session = await client.getWatchSession(channelId);
    } catch (error, stack) {
      if (!_controller.isClosed) _controller.addError(error, stack);
      return;
    }
    if (_controller.isClosed) return;
    if (session == null) {
      // A sample that landed while this read was in flight is newer than its 404.
      if (_applied == appliedBefore) _emit(null);
    } else if (_supersedes(session)) {
      _emit(WatchRoom.fromSession(session, clock()));
    }
  }

  void onTick(api.WatchTick tick) {
    final room = _current;
    if (tick.ended) {
      _onEnded(room, tick);
    } else if (room == null || !room.isSameSession(tick)) {
      if (room == null || tick.epoch >= room.epoch) unawaited(load());
    } else if (tick.sampledAtMs >= room.sampledAtMs) {
      _emit(room.afterTick(tick));
    }
  }

  void _onEnded(WatchRoom? room, api.WatchTick tick) {
    if (room == null ||
        room.botUserId != tick.botUserId ||
        tick.epoch < room.epoch) {
      return;
    }
    _ended = (bot: tick.botUserId, epoch: tick.epoch);
    _emit(null);
  }
}
