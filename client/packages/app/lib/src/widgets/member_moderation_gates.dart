// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a viewer may do about one other member, computed once so every
/// surface that offers a "Moderate..." row - the full member card and any
/// quick-actions menu reached from a call tile or a canvas bubble - shows
/// exactly the same rows for exactly the same reasons.
///
/// Split out of `member_profile.dart`, which computed this inline before a
/// second caller needed the identical answer; moving it here rather than
/// letting a second copy drift is the whole point - see that file's own
/// "reuse its gating, do not reimplement permission checks" precedent for
/// every other surface built on top of it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_rtc/rtc.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart';
import '../providers/channel_permissions.dart';
import '../providers/providers.dart';
import '../providers/voice_flags.dart';

/// Whether a timeout ending at [until] (Unix milliseconds) still holds.
bool timeoutActive(int? until) =>
    until != null && until > DateTime.now().millisecondsSinceEpoch;

/// One viewer's rights over one [profile], and whether they share a call
/// with them right now.
class MemberModerationGates {
  const MemberModerationGates({
    required this.isSelf,
    required this.inCallTogether,
    required this.voiceChannelId,
    required this.outranked,
    required this.canTimeOut,
    required this.canRename,
    required this.canOfferTimeoutChips,
    required this.canRemove,
    required this.canManageRoles,
    required this.canIssueReset,
    required this.canEject,
  });

  final bool isSelf;

  /// Whether the viewer shares a live call with this member right now - the
  /// call section (volume, mute for me) only ever shows while this is true.
  final bool inCallTogether;

  /// The call channel [inCallTogether] refers to, needed to check a
  /// channel-scoped kick overwrite for [canEject]. Null whenever the viewer
  /// is not in a call at all.
  final String? voiceChannelId;

  /// The viewer holds the kick or ban bit but the member's granted permissions
  /// reach beyond theirs, which the server refuses for time out and removal
  /// (`escalation_guard`); false whenever the roles needed to tell are unknown.
  final bool outranked;

  final bool canTimeOut;

  /// Renaming rides the kick bit and the same no-escalation rule as a timeout,
  /// but stays on offer over a member already serving one.
  final bool canRename;

  /// [canTimeOut], narrowed to a member not already timed out - offering the
  /// chips again over a member already serving one reads as the action
  /// having failed.
  final bool canOfferTimeoutChips;
  final bool canRemove;
  final bool canManageRoles;
  final bool canIssueReset;

  /// Needs a room to evict them from, not just the permission bit.
  final bool canEject;

  /// Whether the "Moderate..." row belongs at all - a member with none of
  /// these rights sees no row, never a disabled one.
  bool get showModeration =>
      canOfferTimeoutChips ||
      canRename ||
      canRemove ||
      canManageRoles ||
      canEject ||
      canIssueReset;
}

/// Computes [MemberModerationGates] for [profile] from the viewer's own
/// permissions and call state - the same providers `member_profile.dart`
/// already reads, so a caller elsewhere in the app never has to re-derive
/// what "permitted" means.
///
/// [watch] is true by default, matching `member_profile.dart`'s own reactive
/// popover: its rows must update live if a permission or a call changes
/// while it is open. A caller that only asks once, at the moment a menu
/// happens to be open - `participant_call_menu.dart`'s own quick-actions
/// menu, rebuilt fresh on every open regardless - passes false, since
/// [WidgetRef.watch] is only safe to call during that same widget's own
/// build, which a menu's `itemsBuilder` callback is not.
MemberModerationGates memberModerationGates(
  WidgetRef ref, {
  required api.UserProfile profile,
  bool watch = true,
}) {
  T get<T>(ProviderListenable<T> provider) =>
      watch ? ref.watch(provider) : ref.read(provider);

  final me = get(meProvider).valueOrNull;
  final isSelf = me?.id == profile.id;
  final mine = get(myPermissionsProvider);
  final (voiceState, voiceChannelId) = get(
    voiceFlagsProvider.select((f) => (f.state, f.channelId)),
  );
  final participants = get(voiceParticipantsProvider);
  final inCallTogether =
      voiceState == VoiceSessionState.connected &&
      participants.any((p) => p.identity == profile.id && !p.isLocal);

  final outranked = !isSelf && _outranks(profile, mine, get);
  final canTimeOut =
      !isSelf && !outranked && mine.hasPermission(Perm.kickMembers);
  final canRemove =
      !isSelf && !outranked && mine.hasPermission(Perm.banMembers);
  final canManageRoles = !isSelf && mine.hasPermission(Perm.manageRoles);
  final canIssueReset = !isSelf && mine.hasPermission(Perm.administrator);
  // The voice kick handler checks KICK_MEMBERS in this call's own channel, since an overwrite may grant it there alone.
  final voiceChannelPermissions = voiceChannelId != null
      ? get(myChannelPermissionsProvider(voiceChannelId))
      : 0;
  final canEject =
      !isSelf &&
      inCallTogether &&
      voiceChannelId != null &&
      voiceChannelPermissions.hasPermission(Perm.kickMembers);
  final canOfferTimeoutChips =
      canTimeOut && !timeoutActive(profile.timedOutUntil);

  return MemberModerationGates(
    isSelf: isSelf,
    inCallTogether: inCallTogether,
    voiceChannelId: voiceChannelId,
    outranked: outranked,
    canTimeOut: canTimeOut,
    canRename: canTimeOut,
    canOfferTimeoutChips: canOfferTimeoutChips,
    canRemove: canRemove,
    canManageRoles: canManageRoles,
    canIssueReset: canIssueReset,
    canEject: canEject,
  );
}

/// Whether [profile] holds permissions the viewer does not. Needs the role
/// list, which only MANAGE_ROLES may read, so a viewer without it is never
/// told they are outranked on a guess: the server still refuses.
bool _outranks(
  api.UserProfile profile,
  int mine,
  T Function<T>(ProviderListenable<T>) get,
) {
  if (mine.hasPermission(Perm.administrator) ||
      !mine.hasPermission(Perm.manageRoles)) {
    return false;
  }
  final roles = get(rolesProvider).valueOrNull;
  if (roles == null) return false;
  var granted = 0;
  for (final role in roles) {
    if (role.isEveryone || profile.roleIds.contains(role.id)) {
      granted |= role.permissions;
    }
  }
  return !mine.hasPermission(granted);
}
