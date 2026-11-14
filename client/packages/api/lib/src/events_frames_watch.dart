// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'events.dart';

/// The room's watch position, about every 5 seconds and on every play,
/// pause or seek. Ephemeral: a missed one is corrected by the next, and a
/// bot that just stops ticking is over once the session's lifetime passes.
/// The durable copy is
/// `GET /channels/{channelId}/watch-session`. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
class WatchTick extends ServerEvent {
  const WatchTick({
    required this.channelId,
    required this.botUserId,
    required this.ended,
    required this.itemId,
    required this.playing,
    required this.positionMs,
    required this.sampledAtMs,
    required this.epoch,
  });

  final String channelId;

  /// With [epoch], which session this belongs to.
  final String botUserId;

  /// The bot ended the session or left the call.
  final bool ended;
  final String itemId;
  final bool playing;
  final int positionMs;

  /// The server clock at the sample, the same clock as
  /// [WatchSession.sampledAtMs], so the two can be compared for which is newer.
  final int sampledAtMs;

  /// Changes on every seek or title change and never repeats across an end
  /// and a new session, so a lower one is older.
  final int epoch;
}

/// A member played a soundboard clip in a call this account is in. Delivered
/// only to the accounts in that call, never persisted, so a client plays it
/// once when it arrives and never replays one from a resync.
class SoundboardPlayed extends ServerEvent {
  const SoundboardPlayed({
    required this.channelId,
    required this.clipId,
    required this.playerId,
  });

  final String channelId;
  final String clipId;

  /// Whose per-person volume the clip plays at.
  final String playerId;
}
