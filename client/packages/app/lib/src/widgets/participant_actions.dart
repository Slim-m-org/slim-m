// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which actions one call participant offers, decided in exactly one place.
///
/// The left-click profile card (`member_profile.dart`) and the right-click or
/// long-press quick menu (`participant_call_menu.dart`) both render from this
/// list, so a new action or a changed gate lands on both or neither. Only how
/// an action looks differs per surface: the card shows volume as a slider in
/// place, the menu as a row opening a popover.
library;

enum ParticipantAction { volume, muteForMe, message, viewProfile, moderate }

enum ParticipantSurface { card, menu }

/// The actions [surface] offers, in the order both show them.
///
/// The card is itself the profile, so it never lists [ParticipantAction
/// .viewProfile]. Volume and mute are call-only and local to this listener.
List<ParticipantAction> participantActions({
  required ParticipantSurface surface,
  required bool isSelf,
  required bool inCallTogether,
  required bool supportsVolume,
  required bool hasProfile,
  required bool showModeration,
}) {
  if (isSelf) return const [];
  return [
    if (inCallTogether && supportsVolume) ParticipantAction.volume,
    if (inCallTogether) ParticipantAction.muteForMe,
    if (hasProfile) ParticipantAction.message,
    if (hasProfile && surface == ParticipantSurface.menu)
      ParticipantAction.viewProfile,
    if (hasProfile && showModeration) ParticipantAction.moderate,
  ];
}
