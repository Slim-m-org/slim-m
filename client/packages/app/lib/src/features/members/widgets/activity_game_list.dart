// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The full list of games detection can ever name, so the person can read
/// exactly what the switch covers (decision 0044).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../settings/widgets/settings_section_header.dart';

class ActivityGameList extends StatefulWidget {
  const ActivityGameList({super.key});

  @override
  State<ActivityGameList> createState() => _ActivityGameListState();
}

class _ActivityGameListState extends State<ActivityGameList> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSubRow(
          label: 'Listed games',
          semanticLabel: _open
              ? 'Hide the listed games'
              : 'Show the listed games',
          onTap: () => setState(() => _open = !_open),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.s4,
            children: [
              Text(
                '${gameAllowlist.length} games',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              Icon(
                _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
            ],
          ),
        ),
        if (_open)
          SettingsCardBlock(
            children: [
              Text(
                gameAllowlist.map((game) => game.name).join(', '),
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
      ],
    );
  }
}
