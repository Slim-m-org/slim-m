// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The role chip and module badges of a member row, whole or not at all.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../modules/widgets/module_slot_view.dart';
import 'whole_fit_row.dart';

/// Row chrome besides the name: padding, avatar and the two gaps around the label.
const double _rowChrome = AppSpacing.s8 * 4 + 32;

/// The room a member row leaves for badges once the name has its full width.
double memberRowBadgeRoom(double rowWidth, double nameWidth) =>
    rowWidth - _rowChrome - nameWidth - 1;

/// What a module badge says, for the overflow list.
String moduleBadgeLabel(api.ModuleBadge badge) {
  final texts = [
    for (final node in badge.item.nodes)
      if (node is api.ModuleSlotBadge) node.text,
  ];
  return texts.isEmpty ? (badge.item.fallback ?? badge.name) : texts.join(' ');
}

/// The role chip first, then module badges; whatever does not fit whole folds into a "+N" chip.
class MemberRowBadges extends StatelessWidget {
  const MemberRowBadges({
    required this.maxWidth,
    required this.moduleBadges,
    this.roleChip,
    this.roleLabel,
    super.key,
  });

  final double maxWidth;
  final Widget? roleChip;
  final String? roleLabel;
  final List<api.ModuleBadge> moduleBadges;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      ?roleChip,
      for (final badge in moduleBadges)
        ModuleSlotView(
          badge.item,
          source: badge.moduleId,
          inline: true,
          compact: true,
        ),
    ];
    final labels = [?roleLabel, ...moduleBadges.map(moduleBadgeLabel)];
    if (items.isEmpty || maxWidth <= 0) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: WholeFitRow(
        spacing: AppSpacing.s4,
        items: items,
        overflowChips: [
          for (var hidden = 1; hidden <= items.length; hidden++)
            MemberRowMoreChip(labels.sublist(labels.length - hidden)),
        ],
      ),
    );
  }
}

/// The "+N" chip; the row builds one per possible count and draws the right one.
class MemberRowMoreChip extends StatelessWidget {
  const MemberRowMoreChip(this.hidden, {super.key});

  final List<String> hidden;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Tooltip(
      message: hidden.join(', '),
      triggerMode: TooltipTriggerMode.tap,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        label: '${hidden.length} more: ${hidden.join(', ')}',
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '+${hidden.length}',
              style: AppText.micro.copyWith(
                fontWeight: AppWeights.semi,
                color: tokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
