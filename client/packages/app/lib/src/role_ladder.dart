// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server's role ladder (`http/role_ladder.rs`), mirrored so no surface
/// offers a role change or a moderation act the server would refuse. The
/// server still decides every write.
library;

import 'package:slimm_api/api.dart' as api;

import 'permissions.dart';

/// Why the viewer cannot grant or take away a role from one member.
enum RoleLock {
  /// `@everyone`, which every member holds.
  always,

  /// A bot's own role or the shared Bots role, which follow their bots.
  followsBot,

  /// The role carries a permission the viewer does not hold.
  missingPermissions,

  /// The role is level with or above the viewer's highest role.
  notBelowYou,

  /// The member ranks above the viewer, so their roles are not the viewer's to take.
  memberAboveYou,
}

/// Where the viewer stands: their permissions, whether they own the Space, and
/// their highest role's position (null for none, which ranks below every role).
class RoleLadder {
  const RoleLadder({
    required this.permissions,
    this.isOwner = false,
    this.topPosition,
    this.ranked = true,
  });

  /// [me]'s place. Ranks nobody until [me] is known, when [permissions] are zero and
  /// already hide everything, and against an older server, which enforces no ladder.
  factory RoleLadder.of(api.Me? me, {required int permissions}) => RoleLadder(
    permissions: permissions,
    isOwner: me?.isOwner ?? false,
    topPosition: me?.topRolePosition,
    ranked: me?.reportsRoleLadder ?? false,
  );

  final int permissions;
  final bool isOwner;
  final int? topPosition;

  /// False against a server that predates the ladder, where only permissions count.
  final bool ranked;

  bool get _exempt => isOwner || !ranked;

  /// Whether [role] sits strictly below the viewer's highest role.
  bool reachesRole(api.Role role) {
    final top = topPosition;
    return _exempt || (top != null && role.position < top);
  }

  /// Whether [member] ranks strictly below the viewer, which every moderation act needs.
  bool outranks(api.UserProfile member) {
    if (_exempt) return true;
    if (member.isOwner) return false;
    final mine = topPosition;
    final theirs = member.topRolePosition;
    return mine != null && (theirs == null || theirs < mine);
  }

  /// Why the viewer cannot give [member] [role], or take it away when [held]; null when they can.
  RoleLock? lockOf(
    api.Role role, {
    required api.UserProfile member,
    required bool held,
  }) {
    if (role.isEveryone) return RoleLock.always;
    if (role.isManagedByBot || role.isBotsRole) return RoleLock.followsBot;
    if (held && member.isOwner && !_exempt) return RoleLock.memberAboveYou;
    if (!reachesRole(role)) return RoleLock.notBelowYou;
    if (!permissions.hasPermission(role.permissions)) {
      return RoleLock.missingPermissions;
    }
    return null;
  }
}
