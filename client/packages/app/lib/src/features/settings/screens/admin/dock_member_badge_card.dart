// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Display": whether an installed module's badge shows in the member list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../modules/providers/module_member_badge_settings.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

class DockMemberBadgeCard extends ConsumerWidget {
  const DockMemberBadgeCard({super.key, required this.moduleId});

  final String moduleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.watch(moduleMemberBadgeSettingsProvider);
    return SettingsSectionCard(
      title: 'Display',
      children: [
        SettingsToggleRow(
          label: 'Badge in member list',
          description:
              'Shows its badge beside names; the profile card always keeps it.',
          value: shown.contains(moduleId),
          onChanged: (value) => ref
              .read(moduleMemberBadgeSettingsProvider.notifier)
              .setShown(moduleId, value),
          semanticLabel: 'Show this module badge in the member list',
        ),
      ],
    );
  }
}
