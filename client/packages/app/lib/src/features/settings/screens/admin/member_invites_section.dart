// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space switch for whether any member may invite, beside who may join.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart';

import '../../widgets/space_setting_switch_section.dart';

class MemberInvitesSection extends StatelessWidget {
  const MemberInvitesSection({super.key});

  @override
  Widget build(BuildContext context) => SpaceSettingSwitchSection(
    title: 'Who can invite',
    label: 'Members can invite',
    description: 'Any member can make a one-use link for a day.',
    semanticLabel: 'Let every member invite friends',
    whatFailed: 'change who can invite',
    read: (settings) => settings.membersCanInvite,
    update: (enabled) => SpaceSettingsUpdate(membersCanInvite: enabled),
  );
}
