// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What floats above the rail while an item is carried: the lifted copy under
/// the pointer, and the insertion line, which the copy always sits clear of
/// (see [carriedCopyTop]) so neither hides or strikes through the other.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'rail_drag_lift.dart';
import 'rail_drop_slots.dart';
import 'rail_insertion_line.dart';

/// How far the copy's nearest edge stays from the line's centre: just past the
/// cap, so the copy covers as little of the next row as it can without touching it.
const double carriedCopyClearance =
    (RailInsertionLine.cap + RailInsertionLine.thickness) / 2;

/// Where the carried copy's top goes, in the line's coordinates: where the
/// pointer holds it, unless the line at [lineY] would cross it; then just clear
/// of the line on the pointer's side, so the copy sits on the row it is over.
double carriedCopyTop({
  required double held,
  required double height,
  required double pointerY,
  required double? lineY,
}) {
  if (lineY == null) return held;
  final crosses =
      held < lineY + carriedCopyClearance &&
      held + height > lineY - carriedCopyClearance;
  if (!crosses) return held;
  return pointerY < lineY
      ? lineY - carriedCopyClearance - height
      : lineY + carriedCopyClearance;
}

class RailCarryOverlay extends StatelessWidget {
  const RailCarryOverlay({
    super.key,
    required this.copy,
    required this.at,
    required this.slot,
    required this.size,
    required this.inset,
    required this.lift,
    required this.link,
    required this.listWidth,
  });

  /// What a copy that cannot land where it is says, short enough for the compact rail.
  static const refusedReason = 'Two levels at most';

  final Widget copy;

  /// The global top-left of the item's box, [inset] included.
  final ValueListenable<Offset> at;
  final ValueListenable<DropSlot?> slot;
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
        Positioned.fill(
          child: ValueListenableBuilder<DropSlot?>(
            valueListenable: slot,
            builder: (context, slot, _) => MouseRegion(
              cursor: slot?.refused ?? false
                  ? SystemMouseCursors.forbidden
                  : SystemMouseCursors.grabbing,
            ),
          ),
        ),
        ValueListenableBuilder<Offset>(
          valueListenable: at,
          builder: (context, at, child) {
            final overlay = Overlay.of(context).context.findRenderObject()!;
            final local = (overlay as RenderBox).globalToLocal(at);
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
              child: ValueListenableBuilder<DropSlot?>(
                valueListenable: slot,
                builder: (context, slot, _) {
                  final refused = slot?.refused ?? false;
                  return RailDragLift(
                    animation: lift,
                    refused: refused,
                    child: refused ? _refusedCopy() : copy,
                  );
                },
              ),
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

  Widget _refusedCopy() => Stack(
    fit: StackFit.expand,
    children: [
      copy,
      const Positioned(
        top: 0,
        bottom: 0,
        right: AppSpacing.s8,
        child: Center(child: _RefusedReason()),
      ),
    ],
  );

  Widget _line(DropSlot slot) => CompositedTransformFollower(
    link: link,
    showWhenUnlinked: false,
    offset: Offset(
      AppSpacing.s8 + slot.inset,
      slot.y - RailInsertionLine.thickness / 2,
    ),
    child: Align(
      alignment: Alignment.topLeft,
      child: IgnorePointer(
        child: SizedBox(
          width: listWidth() - 2 * AppSpacing.s8 - slot.inset,
          child: RailInsertionLine(refused: slot.refused),
        ),
      ),
    ),
  );
}

/// The reason on a refused copy, on its own fill so the label beneath never shows through.
class _RefusedReason extends StatelessWidget {
  const _RefusedReason();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.dangerBorder),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s8,
          vertical: AppSpacing.s4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.notAllowed,
              size: AppSizes.icon16,
              color: tokens.dangerText,
            ),
            const SizedBox(width: AppSpacing.s4),
            Text(
              RailCarryOverlay.refusedReason,
              maxLines: 1,
              style: AppText.caption.copyWith(color: tokens.dangerText),
            ),
          ],
        ),
      ),
    );
  }
}
