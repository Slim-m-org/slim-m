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

import 'live_events.dart';
import 'providers.dart';

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
final watchRoomProvider = StreamProvider.autoDispose.family<WatchRoom?, String>((
  ref,
  channelId,
) {
  final client = ref.watch(apiProvider);
  final clock = ref.watch(watchClockProvider);
  final controller = StreamController<WatchRoom?>();
  WatchRoom? current;
  ({String bot, int epoch})? ended;
  var applied = 0;

  void emit(WatchRoom? room) {
    current = room;
    applied++;
    if (!controller.isClosed) controller.add(room);
  }

  bool supersedes(api.WatchSession s) {
    final over = ended;
    if (over != null && s.botUserId == over.bot && s.epoch <= over.epoch) {
      return false;
    }
    final room = current;
    return room == null || room.isNotNewerThan(s);
  }

  Future<void> load() async {
    final appliedBefore = applied;
    final api.WatchSession? session;
    try {
      session = await client.getWatchSession(channelId);
    } catch (error, stack) {
      if (!controller.isClosed) controller.addError(error, stack);
      return;
    }
    if (controller.isClosed) return;
    if (session == null) {
      // A sample that landed while this read was in flight is newer than its 404.
      if (applied == appliedBefore) emit(null);
    } else if (supersedes(session)) {
      emit(WatchRoom.fromSession(session, clock()));
    }
  }

  void onTick(api.WatchTick tick) {
    final room = current;
    if (tick.ended) {
      if (room != null &&
          room.botUserId == tick.botUserId &&
          tick.epoch >= room.epoch) {
        ended = (bot: tick.botUserId, epoch: tick.epoch);
        emit(null);
      }
      return;
    }
    if (room == null || !room.isSameSession(tick)) {
      if (room == null || tick.epoch >= room.epoch) unawaited(load());
      return;
    }
    if (tick.sampledAtMs >= room.sampledAtMs) emit(room.afterTick(tick));
  }

  final sub = ref.read(liveEventsProvider).listen((event) {
    if (event is api.WatchTick && event.channelId == channelId) onTick(event);
  });
  ref.onDispose(() {
    unawaited(sub.cancel());
    unawaited(controller.close());
  });
  unawaited(load());
  return controller.stream;
});
