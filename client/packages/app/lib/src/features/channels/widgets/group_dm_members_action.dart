// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header button that opens a group DM's members sheet, wide or compact.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/header_icon_action.dart';
import 'group_dm_members_sheet.dart';

class GroupDmMembersAction extends StatelessWidget {
  const GroupDmMembersAction({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context) => HeaderIconAction(
    icon: AppIcons.members,
    label: 'Group members',
    onPressed: () => showGroupDmMembersSheet(context, channelId),
  );
}
