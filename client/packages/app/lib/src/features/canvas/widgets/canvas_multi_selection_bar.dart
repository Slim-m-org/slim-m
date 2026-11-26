// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bar over objects picked together: how many, and one Delete, so a phone with no keyboard can remove them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/dock_reservation.dart';
import 'canvas_selection_bar.dart';

class CanvasMultiSelectionBar extends ConsumerWidget {
  const CanvasMultiSelectionBar({
    super.key,
    required this.document,
    required this.armed,
    required this.mayDelete,
    required this.onDelete,
  });

  final CanvasDocument document;

  /// Whether the Move tool is armed, the only tool that picks objects.
  final bool armed;

  /// Whether this person may delete anything in the group.
  final bool Function() mayDelete;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picked = document.multiSelection;
    return AnimatedBuilder(
      animation: Listenable.merge([document, picked.ids, picked.marquee]),
      builder: (context, _) {
        final anchor = _anchor();
        if (anchor == null || !armed || picked.marquee.value != null) {
          return const SizedBox.shrink();
        }
        final bottom = MediaQuery.viewInsetsOf(context).bottom;
        final dock =
            ref.watch(bottomDockReservationProvider) +
            AppSpacing.s12 +
            AppSpacing.s8;
        return Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: CanvasSelectionBarLayout(
              anchor: anchor,
              bottomInset: [
                bottom,
                document.bottomInset,
                dock,
              ].reduce((a, b) => a > b ? a : b),
            ),
            child: _Bar(
              count: picked.ids.value.length,
              mayDelete: mayDelete(),
              onDelete: onDelete,
            ),
          ),
        );
      },
    );
  }

  /// The group's joint box on screen, or null while fewer than two are picked.
  Rect? _anchor() {
    final ids = document.multiSelection.ids.value;
    if (ids.length < 2) return null;
    Rect? joint;
    for (final id in ids) {
      final b = document.objectBounds(id);
      if (b == null) continue;
      final box = Rect.fromLTWH(b.x, b.y, b.w, b.h);
      joint = joint?.expandToInclude(box) ?? box;
    }
    if (joint == null) return null;
    final camera = document.camera;
    return Rect.fromLTWH(
      (joint.left - camera.x) * camera.zoom,
      (joint.top - camera.y) * camera.zoom,
      joint.width * camera.zoom,
      joint.height * camera.zoom,
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.count,
    required this.mayDelete,
    required this.onDelete,
  });

  final int count;
  final bool mayDelete;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final rowHeight = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        container: true,
        label: 'Selection',
        child: Container(
          height: rowHeight + AppSpacing.s8,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.card),
            boxShadow: AppShadows.menu,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.s8,
            children: [
              Text(
                '$count selected',
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
              if (mayDelete)
                FocusableTapTarget(
                  semanticLabel: 'Delete selection',
                  onTap: onDelete,
                  builder: (context, focused, hovered) => Container(
                    padding: const EdgeInsets.all(AppSpacing.s8),
                    decoration: BoxDecoration(
                      color: hovered
                          ? tokens.surfaceSunken
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Icon(
                      AppIcons.delete,
                      size: AppSizes.icon20,
                      color: tokens.dangerText,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
