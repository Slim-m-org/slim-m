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

/// A line just kept in [transcriptId], sent only to the people in the call
/// who may read it. Apply by [TranscriptLine.seq]; a gap means one was
/// missed and the transcript route fills it.
class CallTranscriptLineAdded extends ServerEvent {
  const CallTranscriptLineAdded({
    required this.channelId,
    required this.transcriptId,
    required this.line,
  });

  final String channelId;
  final String transcriptId;
  final TranscriptLine line;
}

/// A mark kept on, or removed from when [mark] is null, a running call's
/// transcript. Sent to the same people as [CallTranscriptLineAdded].
class CallTranscriptMarkChanged extends ServerEvent {
  const CallTranscriptMarkChanged({
    required this.channelId,
    required this.transcriptId,
    required this.markId,
    this.mark,
  });

  final String channelId;
  final String transcriptId;
  final String markId;
  final TranscriptMark? mark;
}

/// The server ended this account's call in [channelId]. Delivered only to the
/// account's own sockets, so the device that was in it can say why.
class VoiceRemoved extends ServerEvent {
  const VoiceRemoved({required this.channelId, required this.reason});

  final String channelId;
  final VoiceRemovalReason reason;
}

enum VoiceRemovalReason {
  /// The account joined a call on another device.
  otherDevice,

  /// A reason newer than this client.
  unknown,
}
