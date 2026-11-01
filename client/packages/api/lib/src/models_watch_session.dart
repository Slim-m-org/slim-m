// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The room's watch session, from `GET /channels/{channelId}/watch-session`.
/// See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

/// How a viewer can reach the media server, and which members the bot has
/// linked to an account there.
class WatchDirectPlay {
  const WatchDirectPlay({
    required this.baseUrl,
    this.verifiedUserIds = const [],
    this.unverifiedUserIds = const [],
  });

  final String baseUrl;

  /// Members whose media server account the bot has verified.
  final List<String> verifiedUserIds;

  /// Members linked only by a claimed name.
  final List<String> unverifiedUserIds;

  factory WatchDirectPlay.fromJson(Map<String, dynamic> json) =>
      WatchDirectPlay(
        baseUrl: json['base_url'] as String,
        verifiedUserIds: [
          for (final id in json['verified_user_ids'] as List? ?? const [])
            id as String,
        ],
        unverifiedUserIds: [
          for (final id in json['unverified_user_ids'] as List? ?? const [])
            id as String,
        ],
      );
}

class WatchSession {
  const WatchSession({
    required this.channelId,
    required this.botUserId,
    required this.itemId,
    required this.title,
    required this.playing,
    required this.positionMs,
    required this.sampledAtMs,
    required this.epoch,
    required this.ttlMs,
    required this.serverTimeMs,
    this.durationMs,
    this.controllerUserId,
    this.directPlay,
    this.directViewerIds = const [],
  });

  final String channelId;
  final String botUserId;
  final String itemId;
  final String title;
  final int? durationMs;
  final bool playing;

  /// Where the room was at [sampledAtMs], not where it is now.
  final int positionMs;
  final int sampledAtMs;

  /// Changes on every seek or title change and never repeats across an end
  /// and a new session.
  final int epoch;

  /// Advisory: who the bot says is steering, for display only.
  final String? controllerUserId;

  /// How long after [sampledAtMs] the session still counts as live.
  final int ttlMs;

  /// The server clock when this was read; [serverTimeMs] minus [sampledAtMs]
  /// is how stale the sample is, on one clock.
  final int serverTimeMs;

  /// What the bot offers a viewer who plays the title themselves, if anything.
  final WatchDirectPlay? directPlay;

  /// Members who reported playing the title themselves in the last 20 seconds.
  final List<String> directViewerIds;

  factory WatchSession.fromJson(Map<String, dynamic> json) => WatchSession(
        channelId: json['channel_id'] as String,
        botUserId: json['bot_user_id'] as String,
        itemId: json['item_id'] as String,
        title: json['title'] as String,
        durationMs: json['duration_ms'] as int?,
        playing: json['playing'] as bool,
        positionMs: json['position_ms'] as int,
        sampledAtMs: json['sampled_at_ms'] as int,
        epoch: json['epoch'] as int,
        controllerUserId: json['controller_user_id'] as String?,
        ttlMs: json['ttl_ms'] as int,
        serverTimeMs: json['server_time_ms'] as int,
        directPlay: json['direct_play'] == null
            ? null
            : WatchDirectPlay.fromJson(
                json['direct_play'] as Map<String, dynamic>,
              ),
        directViewerIds: [
          for (final id in json['direct_viewer_ids'] as List? ?? const [])
            id as String,
        ],
      );
}
