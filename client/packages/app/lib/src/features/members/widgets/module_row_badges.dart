// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The module badges drawn inline in a member row, beside the role chip.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../modules/widgets/module_slot_view.dart';

/// A 236px pane has room for little more than the role chip and two of these.
const int moduleBadgeInlineMax = 2;

/// The badges worth drawing: non-empty, and no more than the row can hold.
List<api.ModuleBadge> visibleModuleBadges(List<api.ModuleBadge>? badges) =>
    badges
        ?.where((badge) => !badge.item.isEmpty)
        .take(moduleBadgeInlineMax)
        .toList(growable: false) ??
    const [];

/// The least room a module badge gets; one that cannot have it is dropped.
const double moduleBadgeMinWidth = 40;

/// Drawn in the room a real role chip leaves, so module badges shrink or drop
/// first. Carries its own leading gap so a dropped set leaves no gap behind.
class ModuleRowBadges extends StatelessWidget {
  const ModuleRowBadges(this.badges, {super.key});

  final List<api.ModuleBadge> badges;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = AppSpacing.s4;
      final room = ((constraints.maxWidth) / (moduleBadgeMinWidth + gap))
          .floor();
      final shown = badges.take(room).toList(growable: false);
      if (shown.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(left: AppSpacing.s4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s4,
          children: [
            for (final badge in shown)
              Flexible(
                child: ModuleSlotView(
                  badge.item,
                  source: badge.moduleId,
                  inline: true,
                ),
              ),
          ],
        ),
      );
    },
  );
}
