// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three wire types a voice call needs: the token that admits you to the
/// SFU room, one participant of a channel's live roster, and the ring that
/// tells the other side of a DM you are calling.
///
/// Split out of models.dart to stay under this repo's line budget, and they
/// are what came out because they are the one group in there that belongs to
/// a single feature rather than to messaging in general.
library;

/// A short-lived credential for a channel's voice room.
///
/// [canPublish] mirrors the SPEAK grant inside the token, so the UI can show a
/// listen-only state up front rather than after the SFU refuses a track.
class VoiceToken {
  const VoiceToken({
    required this.url,
    required this.room,
    required this.token,
    required this.expiresAt,
    required this.canPublish,
  });

  final String url;
  final String room;
  final String token;
  final int expiresAt;
  final bool canPublish;

  factory VoiceToken.fromJson(Map<String, dynamic> json) => VoiceToken(
        url: json['url'] as String,
        room: json['room'] as String,
        token: json['token'] as String,
        expiresAt: json['expires_at'] as int,
        canPublish: json['can_publish'] as bool,
      );
}

/// One participant the server reports as currently connected to a channel's
/// voice room, from `GET /channels/{id}/voice/roster`.
///
/// [displayName] is as it was when this participant joined, not necessarily
/// their current profile name; a participant who chose to appear offline is
/// never sent to any viewer but themselves, so absence from the list is not
/// distinguishable from never having joined.
///
/// [isSharingScreen] and [hasVideo] read straight off the server's own
/// `ListParticipants` call to LiveKit, so they are accurate even when the
/// deployment has no webhook configured for `VoiceScreenShareChanged` (see
/// `docs/decisions/0032-voice-participant-webhooks.md`).
class VoiceRosterParticipant {
  const VoiceRosterParticipant({
    required this.userId,
    required this.displayName,
    this.isSharingScreen = false,
    this.hasVideo = false,
  });

  final String userId;
  final String displayName;
  final bool isSharingScreen;
  final bool hasVideo;

  factory VoiceRosterParticipant.fromJson(Map<String, dynamic> json) =>
      VoiceRosterParticipant(
        userId: json['user_id'] as String,
        displayName: json['display_name'] as String,
        isSharingScreen: json['is_sharing_screen'] as bool? ?? false,
        hasVideo: json['has_video'] as bool? ?? false,
      );
}

/// The listed participants of a voice room and how long the call has run,
/// from `GET /channels/{id}/voice/roster`.
///
/// [callAge] is the age of the longest-present listed participant, measured
/// by the server, so every client reads the same length whatever its own
/// clock says. Null when nobody is listed or the server predates the field.
class VoiceRoster {
  const VoiceRoster({required this.participants, this.callAge});

  final List<VoiceRosterParticipant> participants;
  final Duration? callAge;

  factory VoiceRoster.fromJson(Map<String, dynamic> json) {
    final ageMs = json['call_age_ms'] as int?;
    return VoiceRoster(
      participants: (json['participants'] as List<dynamic>)
          .map(
              (p) => VoiceRosterParticipant.fromJson(p as Map<String, dynamic>))
          .toList(growable: false),
      callAge: ageMs == null ? null : Duration(milliseconds: ageMs),
    );
  }
}

/// A DM call ring the caller just started, from `POST
/// /channels/{id}/voice/ring`.
class RingStarted {
  const RingStarted({required this.ringId, required this.timeoutMs});

  final String ringId;

  /// How long the server itself waits for an answer before giving up on this
  /// ring; a client renders its own countdown from this rather than a
  /// hard-coded duration that could drift from the server's.
  final int timeoutMs;

  factory RingStarted.fromJson(Map<String, dynamic> json) => RingStarted(
        ringId: json['ring_id'] as String,
        timeoutMs: json['timeout_ms'] as int,
      );
}

/// A DM call ring still waiting on this account, from `GET
/// /voice/rings/incoming`.
class OutstandingDmCallRing {
  const OutstandingDmCallRing({
    required this.channelId,
    required this.ringId,
    required this.callerId,
    required this.remainingMs,
  });

  final String channelId;
  final String ringId;
  final String callerId;
  final int remainingMs;

  factory OutstandingDmCallRing.fromJson(Map<String, dynamic> json) =>
      OutstandingDmCallRing(
        channelId: json['channel_id'] as String,
        ringId: json['ring_id'] as String,
        callerId: json['caller_id'] as String,
        remainingMs: json['remaining_ms'] as int,
      );
}
