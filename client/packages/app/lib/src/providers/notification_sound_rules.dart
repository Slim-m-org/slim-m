// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure decision logic for which chime (if any) an event deserves, kept
/// apart from the Riverpod and stream wiring in
/// `notification_sound_controller.dart` so it is testable with no provider
/// container, fake stream, or widget at all.
library;

import 'package:slimm_api/api.dart' as api;

import '../audio/notification_sound.dart';

/// Whether an incoming message is even a candidate for a sound: not this
/// device's own send, not from someone blocked, and from an author who still
/// exists (an anonymised account carries no [authorId] to compare).
bool messageEarnsASound({
  required String? authorId,
  required String? selfId,
  required bool authorBlocked,
}) => authorId != null && authorId != selfId && !authorBlocked;

/// Which of the three message chimes a message that already
/// [messageEarnsASound] gets. A DM always wins over a mention: `sounds.py`'s
/// own description calls a DM "the single most personal event" and a
/// mention only "a direct message with an edge", so the two never layer.
NotificationSound messageSoundKind({
  required bool isDm,
  required bool mentionsSelf,
}) {
  if (isDm) return NotificationSound.directMessage;
  if (mentionsSelf) return NotificationSound.mention;
  return NotificationSound.groupMessage;
}

/// Whether the preference that applies to a message still allows it through
/// to an alert, mirroring the server's own
/// `push::recipients::narrow_for_notification_preference` gate so a muted
/// channel neither chimes nor pushes. `channelOverride` is the resolved
/// preference (channel, else thread parent, else account; see
/// `message_alert_policy.dart`), `null` when none is known - unaffected, the
/// same behaviour every channel had before these preferences existed.
bool channelEarnsASound({
  required api.NotificationPreference? channelOverride,
  required bool isDm,
  required bool mentionsSelf,
}) => switch (channelOverride) {
  null || api.NotificationPreference.everything => true,
  api.NotificationPreference.nothing => false,
  api.NotificationPreference.mentions => isDm || mentionsSelf,
};

/// Above this many participants (self included), join/leave chimes stop -
/// the owner's own decision, "roughly 8", recorded in CLAUDE.md and already
/// echoed in the Sounds settings copy before anything played them.
const soundsDisabledAboveParticipants = 8;

/// One step of a voice roster diff: who newly joined or left since
/// [previousIdentities], and the identity set to remember for next time.
class RosterDiff {
  const RosterDiff({
    required this.joined,
    required this.left,
    required this.baseline,
  });

  final Set<String> joined;
  final Set<String> left;
  final Set<String> baseline;
}

/// [previousIdentities] null means "just connected, nothing to compare
/// against yet": the roster already in the room the moment this device
/// arrives must read as a snapshot, never as a burst of live joins, the same
/// shape `SyncController`'s own catch-up-versus-live split already draws.
RosterDiff diffRoster(
  Set<String>? previousIdentities,
  Set<String> currentIdentities,
) {
  if (previousIdentities == null) {
    return RosterDiff(
      joined: const {},
      left: const {},
      baseline: currentIdentities,
    );
  }
  return RosterDiff(
    joined: currentIdentities.difference(previousIdentities),
    left: previousIdentities.difference(currentIdentities),
    baseline: currentIdentities,
  );
}
