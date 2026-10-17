// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What floats above the rail while an item is carried: the lifted copy under
/// the pointer, and the insertion line drawn over it so the copy never hides
/// where the item will land.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import 'rail_drag_lift.dart';
import 'rail_drop_slots.dart';
import 'rail_insertion_line.dart';

class RailCarryOverlay extends StatelessWidget {
  const RailCarryOverlay({
    super.key,
    required this.copy,
    required this.pointer,
    required this.slot,
    required this.grab,
    required this.size,
    required this.inset,
    required this.lift,
    required this.link,
    required this.listWidth,
  });

  final Widget copy;
  final ValueListenable<Offset> pointer;
  final ValueListenable<DropSlot?> slot;

  /// Where within the item the pointer took hold, so the copy does not jump.
  final Offset grab;
  final Size size;

  /// The gap left of the item's face inside [size], which the copy omits.
  final double inset;
  final Animation<double> lift;

  /// Anchored on the rail's list, so a y in its coordinates lands correctly.
  final LayerLink link;
  final double Function() listWidth;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: MouseRegion(cursor: SystemMouseCursors.grabbing),
        ),
        ValueListenableBuilder<Offset>(
          valueListenable: pointer,
          builder: (context, at, child) {
            final overlay = Overlay.of(context).context.findRenderObject()!;
            final local = (overlay as RenderBox).globalToLocal(at - grab);
            return Positioned(
              left: local.dx + inset,
              top: local.dy,
              width: size.width - inset,
              height: size.height,
              child: child!,
            );
          },
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RailDragLift(animation: lift, child: copy),
            ),
          ),
        ),
        ValueListenableBuilder<DropSlot?>(
          valueListenable: slot,
          builder: (context, slot, _) =>
              slot == null ? const SizedBox.shrink() : _line(slot),
        ),
      ],
    );
  }

  Widget _line(DropSlot slot) => CompositedTransformFollower(
    link: link,
    showWhenUnlinked: false,
    offset: Offset(AppSpacing.s8, slot.y - RailInsertionLine.thickness / 2),
    child: Align(
      alignment: Alignment.topLeft,
      child: IgnorePointer(
        child: SizedBox(
          width: listWidth() - 2 * AppSpacing.s8,
          child: const RailInsertionLine(),
        ),
      ),
    ),
  );
}
