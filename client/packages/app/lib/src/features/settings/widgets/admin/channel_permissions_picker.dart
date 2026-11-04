// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "add a role or member" flow for the permissions grid: one searchable
/// sheet of roles and members. Split out of `channel_permissions_grid.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'channel_permissions_grid_rows.dart';
import 'overwrite_target_picker.dart';

/// Resolves to the chosen column, or null when the user backs out. Columns
/// whose keys are in [taken] are not offered.
Future<GridColumn?> pickGridColumn(
  BuildContext context, {
  Set<String> taken = const {},
}) async {
  final picked = await showAppSheet<Object>(
    context,
    builder: (context) => OverwriteTargetPicker(taken: taken),
  );
  return switch (picked) {
    api.Role role => GridColumn(
      kind: api.OverwriteTarget.role,
      id: role.id,
      label: role.name,
      isBot: false,
    ),
    api.UserProfile member => GridColumn(
      kind: api.OverwriteTarget.member,
      id: member.id,
      label: member.displayName,
      isBot: member.isBot,
    ),
    _ => null,
  };
}
