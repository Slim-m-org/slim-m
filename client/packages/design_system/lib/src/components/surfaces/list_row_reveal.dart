// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_motion.dart';

/// `AppListRow.trailingExtra` when the row reveals it on hover: shown while
/// [hovered] or focused, otherwise no width, gap included. It stays mounted,
/// so focusing it survives the reveal that focusing it triggers.
class ListRowRevealSlot extends StatefulWidget {
  const ListRowRevealSlot({
    super.key,
    required this.hovered,
    required this.child,
  });

  final bool hovered;
  final Widget child;

  @override
  State<ListRowRevealSlot> createState() => _ListRowRevealSlotState();
}

class _ListRowRevealSlotState extends State<ListRowRevealSlot> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final shown = widget.hovered || _focused;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      // Its own annotations would merge with the child's and take this zero-width slot's rect.
      includeSemantics: false,
      onFocusChange: (v) => setState(() => _focused = v),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        widthFactor: shown ? 1 : 0,
        heightFactor: 1,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          // Instant on the way out: the label has already taken the space back.
          duration: shown
              ? AppMotion.reduced(context, AppMotion.fast)
              : Duration.zero,
          alwaysIncludeSemantics: true,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: AppSpacing.s8),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
