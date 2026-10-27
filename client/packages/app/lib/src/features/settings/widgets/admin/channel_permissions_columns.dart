// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure helpers that turn pending overwrite keys into grid columns.
library;

import 'package:slimm_api/api.dart' as api;

import '../../../../permissions.dart';
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
GridColumn gridColumnWithCounts(GridColumn column, (int, int) pending) {
  final (allow, deny) = pending;
  return GridColumn(
    kind: column.kind,
    id: column.id,
    label: column.label,
    isBot: column.isBot,
    allowCount: _countKnown(allow),
    denyCount: _countKnown(deny),
  );
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
