// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two-step "add a role or member" flow for the permissions grid: pick the
/// kind, then the principal. Split out of `channel_permissions_grid.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'channel_permissions_grid_rows.dart';
import 'overwrite_target_picker_sheets.dart';

/// Resolves to the chosen column, or null when the user backs out at either
/// step or [context] is gone by then.
Future<GridColumn?> pickGridColumn(BuildContext context) async {
  final kind = await showAppSheet<api.OverwriteTarget>(
    context,
    builder: (context) => const AddColumnKindSheet(),
  );
  if (kind == null || !context.mounted) return null;
  if (kind == api.OverwriteTarget.role) {
    final role = await showAppSheet<api.Role>(
      context,
      builder: (context) => const RolePickerSheet(),
    );
    if (role == null) return null;
    return GridColumn(kind: kind, id: role.id, label: role.name, isBot: false);
  }
  final member = await showAppSheet<api.UserProfile>(
    context,
    builder: (context) => const MemberPickerSheet(),
  );
  if (member == null) return null;
  return GridColumn(
    kind: kind,
    id: member.id,
    label: member.displayName,
    isBot: member.isBot,
  );
}
