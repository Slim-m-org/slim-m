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
          for (final game in gameAllowlist) _GameRow(name: game.name),
      ],
    );
  }
}

class _GameRow extends StatelessWidget {
  const _GameRow({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      constraints: const BoxConstraints(minHeight: AppSpacing.s48),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      child: Row(
        spacing: AppSpacing.s12,
        children: [
          Container(
            width: AppSpacing.s32,
            height: AppSpacing.s32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.surfaceSunken,
              border: Border.all(color: tokens.borderSubtle),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: ExcludeSemantics(
              child: Text(
                name.characters.first.toUpperCase(),
                style: AppText.caption.copyWith(
                  color: tokens.textSecondary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(color: tokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
