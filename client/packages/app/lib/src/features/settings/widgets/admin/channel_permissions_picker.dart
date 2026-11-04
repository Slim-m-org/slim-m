// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "add a role or member" flow for the permissions grid: one sheet of
/// roles with a member row that opens the member search. Split out of
/// `channel_permissions_grid.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'channel_permissions_grid_rows.dart';
import 'overwrite_target_picker_sheets.dart';
import '../../../members/widgets/member_picker.dart';

/// Resolves to the chosen column, or null when the user backs out or
/// [context] is gone by then.
Future<GridColumn?> pickGridColumn(BuildContext context) async {
  final picked = await showAppSheet<Object>(
    context,
    builder: (context) => const RolePickerSheet(offerMember: true),
  );
  if (picked is api.Role) {
    return GridColumn(
      kind: api.OverwriteTarget.role,
      id: picked.id,
      label: picked.name,
      isBot: false,
    );
  }
  if (picked == null || !context.mounted) return null;
  final member = await pickMember(context);
  if (member == null) return null;
  return GridColumn(
    kind: api.OverwriteTarget.member,
    id: member.id,
    label: member.displayName,
    isBot: member.isBot,
  );
}
