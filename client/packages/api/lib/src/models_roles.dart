// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Roles and channel permission overwrites.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

/// A role: a name plus a permission bitmask, assignable to members and
/// checked the same way whether it came from `@everyone` or a created role.
class Role {
  const Role({
    required this.id,
    required this.name,
    required this.permissions,
    required this.isEveryone,
    this.mentionable = false,
    this.hoist = false,
    this.color,
    required this.createdAt,
    this.managedBotId,
    this.position = 0,
    this.memberCount = 0,
  });

  final String id;
  final String name;

  /// The raw permission bitmask; see the server's `Permissions` type for what
  /// each bit means.
  final int permissions;

  /// Whether this is the deployment's single `@everyone` base role. Exactly
  /// one role always carries this.
  final bool isEveryone;

  /// Whether any member may wake this role's members with `@[Role Name]`
  /// with no permission of their own. Defaults false; a member holding
  /// `Perm.mentionEveryone` can still wake it regardless.
  final bool mentionable;

  /// Whether the member pane lists this role's members under their own
  /// heading. Defaults false, also on a server older than the field.
  final bool hoist;

  /// An index into the role palette, or null for the colour derived from the id.
  final int? color;

  /// Unix milliseconds.
  final int createdAt;

  /// Informational: the bot this role was minted for, if any. An ordinary,
  /// freely editable role otherwise. See `docs/decisions/0028-bot-accounts.md`.
  final String? managedBotId;

  /// Hierarchy order: higher sorts first, matching the order `listRoles`
  /// already returns them in. `@everyone` always sorts last.
  final int position;

  /// How many members currently hold this role; `@everyone`'s counts the
  /// whole deployment.
  final int memberCount;

  /// Whether to show the "Bot" badge.
  bool get isManagedByBot => managedBotId != null;

  factory Role.fromJson(Map<String, dynamic> json) => Role(
        id: json['id'] as String,
        name: json['name'] as String,
        permissions: json['permissions'] as int,
        isEveryone: json['is_everyone'] as bool,
        mentionable: json['mentionable'] as bool? ?? false,
        hoist: json['hoist'] as bool? ?? false,
        color: json['color'] as int?,
        createdAt: json['created_at'] as int,
        managedBotId: json['managed_bot_id'] as String?,
        position: json['position'] as int? ?? 0,
        memberCount: json['member_count'] as int? ?? 0,
      );
}

/// What a channel permission overwrite targets: a role held by many members,
/// or one member directly.
enum OverwriteTarget {
  role,
  member;

  String get wire => name;

  /// An unrecognised kind reads as [member]: a channel that could not
  /// resolve to a role stays put on the narrower, single-account reading
  /// rather than one this client would apply to a whole group of members.
  static OverwriteTarget parse(String value) =>
      value == 'role' ? OverwriteTarget.role : OverwriteTarget.member;
}

/// One permission overwrite already set on a channel: the current allow/deny
/// pair for one role or member, as `GET /channels/{channelId}/overwrites`
/// returns it. This is the read [SlimmApiRoles.setChannelOverwrite] never
/// had - without it, a routine edit could only replace an overwrite sight
/// unseen, silently re-granting a deliberate denial.
class ChannelOverwrite {
  const ChannelOverwrite({
    required this.kind,
    required this.id,
    required this.allow,
    required this.deny,
  });

  final OverwriteTarget kind;

  /// The role's or member's UUID, matching [kind].
  final String id;

  /// The permission bits this overwrite forces on.
  final int allow;

  /// The permission bits this overwrite forces off.
  final int deny;

  factory ChannelOverwrite.fromJson(Map<String, dynamic> json) =>
      ChannelOverwrite(
        kind: OverwriteTarget.parse(json['kind'] as String),
        id: json['id'] as String,
        allow: json['allow'] as int,
        deny: json['deny'] as int,
      );
}

/// One target's full allow/deny replacement, as
/// [SlimmApiRoles.batchSetChannelOverwrites] sends it - the write-side
/// mirror of [ChannelOverwrite], which is read-only.
class ChannelOverwriteEdit {
  const ChannelOverwriteEdit({
    required this.kind,
    required this.id,
    this.allow = 0,
    this.deny = 0,
  });

  final OverwriteTarget kind;
  final String id;
  final int allow;
  final int deny;
}

/// A grantable module-scoped permission, registered by the Dock's install
/// handler - the dynamic half of the permission model alongside the fixed
/// bitmask [Role.permissions]. See
/// `docs/decisions/0021-modules-and-the-dock.md`.
class ModulePermission {
  const ModulePermission({
    required this.moduleId,
    required this.moduleName,
    required this.permKey,
    required this.name,
    required this.description,
  });

  final String moduleId;
  final String moduleName;
  final String permKey;
  final String name;
  final String description;

  factory ModulePermission.fromJson(Map<String, dynamic> json) =>
      ModulePermission(
        moduleId: json['module_id'] as String,
        moduleName: json['module_name'] as String,
        permKey: json['perm_key'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
      );
}

/// One module permission a role currently holds.
class GrantedModulePermission {
  const GrantedModulePermission({
    required this.moduleId,
    required this.permKey,
  });

  final String moduleId;
  final String permKey;

  factory GrantedModulePermission.fromJson(Map<String, dynamic> json) =>
      GrantedModulePermission(
        moduleId: json['module_id'] as String,
        permKey: json['perm_key'] as String,
      );
}
