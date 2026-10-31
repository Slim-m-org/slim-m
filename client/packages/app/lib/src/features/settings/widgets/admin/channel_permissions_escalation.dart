// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The escalation rule the server enforces on overwrite writes, mirrored so
/// the grid can refuse a save by permission name before sending it.
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

/// The sentence a refused save shows, naming what the caller cannot grant.
String escalationMessage(int bits) {
  final names = permissionLabels(bits);
  final list = joinLabels(names);
  return 'Could not save the permissions grid. You cannot grant $list, '
      'so leave ${names.length == 1 ? 'it' : 'them'} as they were.';
}
