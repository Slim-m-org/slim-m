// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The full list of games detection can ever name, so the person can read
/// exactly what the switch covers (decision 0044).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppButton(
            label: _open
                ? 'Hide the ${gameAllowlist.length} listed games'
                : 'Show the ${gameAllowlist.length} listed games',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.sm,
            onPressed: () => setState(() => _open = !_open),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Text(
                gameAllowlist.map((game) => game.name).join(', '),
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
