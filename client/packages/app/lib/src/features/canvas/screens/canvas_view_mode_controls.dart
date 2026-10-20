// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pill that names the canvas view and switches it, and the way back from
/// a layout this viewer made for themselves. Decision 0082.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class CanvasViewModeControls extends StatelessWidget {
  const CanvasViewModeControls({
    super.key,
    required this.mode,
    required this.tokens,
  });

  final CanvasViewMode mode;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([mode, mode.tiles]),
    builder: (context, _) {
      final personal = mode.personal;
      return Wrap(
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s8,
        children: [
          _Pill(
            tokens: tokens,
            selected: personal,
            icon: personal ? AppIcons.account : AppIcons.members,
            label: personal ? 'Personal view' : 'Shared view',
            semanticLabel:
                '${personal ? 'Personal view' : 'Shared view'}, '
                'switch to ${personal ? 'shared' : 'personal'}',
            tooltip: personal
                ? 'Back to the shared board'
                : 'Move and zoom for yourself only',
            onTap: mode.toggle,
          ),
          if (mode.hasLayout)
            _Pill(
              tokens: tokens,
              selected: false,
              icon: AppIcons.undo,
              label: 'Reset my layout',
              semanticLabel: 'Reset my layout, return to the shared view',
              onTap: mode.reset,
            ),
        ],
      );
    },
  );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.tokens,
    required this.selected,
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.tooltip,
  });

  final AppTokens tokens;
  final bool selected;
  final IconData icon;
  final String label;
  final String semanticLabel;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = selected ? tokens.accent : tokens.textSecondary;
    final pill = Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      hint: tooltip,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? tokens.accentSoft : tokens.surfaceRaised,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? tokens.accent : tokens.borderSubtle,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSizes.icon28),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: AppSizes.icon16, color: colour),
                  const SizedBox(width: AppSpacing.s4),
                  Text(
                    label,
                    style: AppText.caption.copyWith(
                      color: colour,
                      fontWeight: AppWeights.medium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // The hint above carries the tooltip; its own node would merge into the canvas surface's label.
    return AppTouchHitArea(
      child: tooltip == null
          ? pill
          : Tooltip(message: tooltip!, excludeFromSemantics: true, child: pill),
    );
  }
}
