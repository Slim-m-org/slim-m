// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which actions one call participant offers, decided in exactly one place.
///
/// The left-click profile card (`member_profile.dart`) and the right-click or
/// long-press quick menu (`participant_call_menu.dart`) both render from this
/// list, so a new action or a changed gate lands on both or neither. Only how
/// an action looks differs per surface: the card shows volume as a slider in
/// place, the menu as a row opening a popover.
library;

enum ParticipantAction {
  volume,
  muteForMe,
  message,
  call,
  viewProfile,
  moveTo,
  moderate,
}

enum ParticipantSurface { card, menu }

/// What [participantActions] needs to know about one participant and the
/// surface asking.
class ParticipantActionContext {
  const ParticipantActionContext({
    required this.surface,
    required this.isSelf,
    required this.inCallTogether,
    required this.supportsVolume,
    required this.hasProfile,
    required this.showModeration,
    this.canCall = false,
    this.canMove = false,
  });

  final ParticipantSurface surface;
  final bool isSelf;
  final bool inCallTogether;
  final bool supportsVolume;
  final bool hasProfile;
  final bool showModeration;
  final bool canCall;
  final bool canMove;
}

/// The actions [surface] offers, in the order both show them.
///
/// The card is itself the profile, so it never lists [ParticipantAction
/// .viewProfile]. Volume and mute are call-only and local to this listener;
/// Call is the reverse, offered only to someone you are not already in a call
/// with, and only where the caller says calling them is possible.
List<ParticipantAction> participantActions(ParticipantActionContext context) {
  final ParticipantActionContext(
    :surface,
    :isSelf,
    :inCallTogether,
    :supportsVolume,
    :hasProfile,
    :showModeration,
    :canCall,
    :canMove,
  ) = context;
  if (isSelf) return const [];
  return [
    if (inCallTogether && supportsVolume) ParticipantAction.volume,
    if (inCallTogether) ParticipantAction.muteForMe,
    if (hasProfile) ParticipantAction.message,
    if (hasProfile && canCall && !inCallTogether) ParticipantAction.call,
    if (hasProfile && surface == ParticipantSurface.menu)
      ParticipantAction.viewProfile,
    if (canMove && surface == ParticipantSurface.menu) ParticipantAction.moveTo,
    if (hasProfile && showModeration) ParticipantAction.moderate,
  ];
}
