// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure helpers that turn pending overwrite keys into grid columns.
library;

import 'package:slimm_api/api.dart' as api;

import '../../../../permissions.dart';
import '../../../../role_ladder.dart';
import 'channel_permissions_grid_rows.dart';

/// Splits a `role:<id>` or `member:<id>` pending key into its target and id.
(api.OverwriteTarget, String) parseOverwriteKey(String key) {
  final i = key.indexOf(':');
  final kind = key.substring(0, i) == 'role'
      ? api.OverwriteTarget.role
      : api.OverwriteTarget.member;
  return (kind, key.substring(i + 1));
}

int _countKnown(int mask) => Perm.groups
    .expand((g) => g.permissions)
    .where((spec) => mask & spec.bit != 0)
    .length;

/// [column] carrying how many permissions its pending allow and deny masks set.
GridColumn gridColumnWithCounts(
  GridColumn column,
  (int, int) pending, {
  bool locked = false,
}) {
  final (allow, deny) = pending;
  return GridColumn(
    kind: column.kind,
    id: column.id,
    label: column.label,
    isBot: column.isBot,
    allowCount: _countKnown(allow),
    denyCount: _countKnown(deny),
    locked: locked,
    isEveryone: column.isEveryone,
  );
}

/// Which overwrites the viewer may write, as the server's `reach_target` decides: `@everyone`
/// and their own always, any other role or member only below them.
class OverwriteReach {
  const OverwriteReach({
    required this.ladder,
    required this.selfId,
    required this.roles,
    required this.members,
  });

  final RoleLadder ladder;
  final String? selfId;
  final List<api.Role> roles;
  final List<api.UserProfile> members;

  bool reaches(String key) {
    final (kind, id) = parseOverwriteKey(key);
    if (kind == api.OverwriteTarget.role) {
      final role = roles.where((r) => r.id == id).firstOrNull;
      return role == null || role.isEveryone || ladder.reachesRole(role);
    }
    if (id == selfId) return true;
    final member = members.where((m) => m.id == id).firstOrNull;
    return member == null || ladder.outranks(member);
  }

  /// Every role and member the viewer may not write, which the picker leaves out.
  Set<String> get outrankedKeys => {
    for (final r in roles)
      if (!reaches('role:${r.id}')) 'role:${r.id}',
    for (final m in members)
      if (!reaches('member:${m.id}')) 'member:${m.id}',
  };

  /// The names of those among [keys] the viewer may not write.
  List<String> outrankedLabels(Iterable<String> keys) => [
    for (final key in keys)
      if (!reaches(key)) resolveGridColumn(key, roles, members)?.label ?? key,
  ];
}

/// The column for a pending [key], or null when its role or member is gone.
GridColumn? resolveGridColumn(
  String key,
  List<api.Role> roles,
  List<api.UserProfile> members,
) {
  final (kind, id) = parseOverwriteKey(key);
  if (kind == api.OverwriteTarget.role) {
    final role = roles.where((r) => r.id == id).firstOrNull;
    if (role == null) return null;
    return GridColumn(kind: kind, id: id, label: role.name, isBot: false);
  }
  final member = members.where((m) => m.id == id).firstOrNull;
  if (member == null) return null;
  return GridColumn(
    kind: kind,
    id: id,
    label: member.displayName,
    isBot: member.isBot,
  );
}
