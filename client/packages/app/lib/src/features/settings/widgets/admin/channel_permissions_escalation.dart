// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The escalation and rank rules the server enforces on overwrite writes,
/// mirrored so the grid can refuse a save by name before sending it.
library;

import '../../../../permissions.dart';

/// Bits a change from ([oldAllow], [oldDeny]) to ([newAllow], [newDeny])
/// would grant that [myPermissions] does not hold. Lifting a deny counts as
/// granting, same as `batch_set` in the server's `http/overwrites.rs`.
int escalatedBits({
  required int oldAllow,
  required int oldDeny,
  required int newAllow,
  required int newDeny,
  required int myPermissions,
}) => ((newAllow & ~oldAllow) | (oldDeny & ~newDeny)) & ~myPermissions;

/// Bits a save of [pending] over [original] would grant that [myPermissions] does not hold; a
/// [removed] column lifts its denies.
int pendingEscalation({
  required Map<String, (int, int)> original,
  required Map<String, (int, int)> pending,
  required Set<String> removed,
  required int myPermissions,
}) {
  var bits = 0;
  for (final key in removed) {
    final (_, deny) = original[key] ?? (0, 0);
    bits |= deny & ~myPermissions;
  }
  for (final entry in pending.entries) {
    final (oldAllow, oldDeny) = original[entry.key] ?? (0, 0);
    bits |= escalatedBits(
      oldAllow: oldAllow,
      oldDeny: oldDeny,
      newAllow: entry.value.$1,
      newDeny: entry.value.$2,
      myPermissions: myPermissions,
    );
  }
  return bits;
}

/// The sentence a refused save shows, naming what the caller cannot grant.
String escalationMessage(int bits) {
  final names = permissionLabels(bits);
  final list = joinLabels(names);
  return 'Could not save the permissions grid. You cannot grant $list, '
      'so leave ${names.length == 1 ? 'it' : 'them'} as they were.';
}

/// The sentence a save refused by the role ladder shows, naming the columns.
String outrankedMessage(List<String> names) =>
    'Could not save the permissions grid. ${joinLabels(names)} '
    '${names.length == 1 ? 'ranks' : 'rank'} level with or above you, so '
    'leave ${names.length == 1 ? 'it' : 'them'} as ${names.length == 1 ? 'it was' : 'they were'}.';
