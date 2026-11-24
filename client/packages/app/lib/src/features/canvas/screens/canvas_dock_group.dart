// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas dock's one rhythm: buttons in a group sit [canvasDockButtonGap]
/// apart, and groups are told apart by a divider with [canvasDockGroupPadding]
/// on each side, wherever the dock draws them.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/floating_dock_card.dart';

/// Space on each side of a group divider; touch buttons already carry their own room.
double canvasDockGroupPadding(BuildContext context) =>
    AppTouchTargets.of(context) ? 0 : AppSpacing.s8;

/// Space between two buttons of one group; touch targets already carry their own room.
double canvasDockButtonGap(BuildContext context) =>
    AppTouchTargets.of(context) ? 0 : AppSpacing.s4;

/// A thin vertical rule with the same room either side, between two groups.
class CanvasDockGroupDivider extends StatelessWidget {
  const CanvasDockGroupDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final pad = SizedBox(width: canvasDockGroupPadding(context));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [pad, const DockVerticalDivider(), pad],
    );
  }
}

/// [groups] as one row's children: the button gap inside a group, a divider between groups.
List<Widget> canvasDockGroups(BuildContext context, List<List<Widget>> groups) {
  final gap = SizedBox(width: canvasDockButtonGap(context));
  final out = <Widget>[];
  for (final group in groups.where((g) => g.isNotEmpty)) {
    if (out.isNotEmpty) out.add(const CanvasDockGroupDivider());
    for (var i = 0; i < group.length; i++) {
      if (i > 0) out.add(gap);
      out.add(group[i]);
    }
  }
  return out;
}
