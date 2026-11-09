// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space switch that takes bots out of the member list, beside the bots themselves.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart';

import '../../widgets/space_setting_switch_section.dart';

class BotMemberListSection extends StatelessWidget {
  const BotMemberListSection({super.key});

  @override
  Widget build(BuildContext context) => SpaceSettingSwitchSection(
    title: 'Member list',
    label: 'Hide bots',
    description: 'They still appear in mentions and voice.',
    semanticLabel: 'Hide bots from the member list',
    whatFailed: 'change the member list',
    read: (settings) => settings.hideBotsInMemberList,
    update: (hidden) => SpaceSettingsUpdate(hideBotsInMemberList: hidden),
  );
}
