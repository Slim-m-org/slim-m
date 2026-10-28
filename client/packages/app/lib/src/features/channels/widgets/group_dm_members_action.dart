// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header button that opens a group DM's members sheet, wide or compact.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'group_dm_members_sheet.dart';

class GroupDmMembersAction extends StatelessWidget {
  const GroupDmMembersAction({
    super.key,
    required this.channelId,
    this.touch = false,
  });

  final String channelId;

  /// The compact bar's 44dp target.
  final bool touch;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: AppIcons.members,
    semanticLabel: 'Group members',
    tooltip: touch ? null : 'Group members',
    touch: touch,
    onPressed: () => showGroupDmMembersSheet(context, channelId),
  );
}
