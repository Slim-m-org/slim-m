// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pick-one group drawn as one line of visual tiles inside a control's
/// options menu, for choices a person reads by looking (a colour, a width).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Anything a control's options menu can hold.
abstract class ControlOptionEntry {
  const ControlOptionEntry();
}

/// One tile of a [ControlSwatchGroup]. [label] is never drawn; it is the
/// tooltip and what assistive tech announces, e.g. "Coral, selected".
class ControlSwatch {
  const ControlSwatch({
    required this.label,
    required this.selected,
    required this.onSelected,
    this.color,
    this.lineWidth,
    this.mark,
    this.disabledReason,
  }) : assert(
         (color == null ? 0 : 1) +
                 (lineWidth == null ? 0 : 1) +
                 (mark == null ? 0 : 1) ==
             1,
         'a tile shows one of a colour dot, a line sample or a mark',
       );

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  /// Draws a filled colour dot.
  final Color? color;

  /// Draws a horizontal line sample this thick.
  final double? lineWidth;

  /// Draws this widget as it is, for a choice neither a colour nor a width
  /// describes, such as an emoji.
  final Widget? mark;

  /// Dims the tile and says why it cannot be picked; null leaves it live.
  final String? disabledReason;
}

/// A [heading] and its [swatches] on a single line.
class ControlSwatchGroup extends ControlOptionEntry {
  const ControlSwatchGroup({required this.heading, required this.swatches});

  final String heading;
  final List<ControlSwatch> swatches;
}

/// The row itself. Each tile shares the width equally and is never shorter
/// than the row height at the current density (law 2), so six of them fit a
/// 200dp menu at pointer density and a 390dp sheet at touch density.
class ControlSwatchRow extends StatelessWidget {
  const ControlSwatchRow({
    super.key,
    required this.swatches,
    required this.close,
  });

  final List<ControlSwatch> swatches;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final height = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          for (final swatch in swatches)
            Expanded(
              child: _SwatchTile(swatch: swatch, close: close),
            ),
        ],
      ),
    );
  }
}

class _SwatchTile extends StatefulWidget {
  const _SwatchTile({required this.swatch, required this.close});

  final ControlSwatch swatch;
  final VoidCallback close;

  @override
  State<_SwatchTile> createState() => _SwatchTileState();
}

class _SwatchTileState extends State<_SwatchTile> {
  bool _hovered = false;
  bool _focused = false;

  void _select() {
    AppHaptics.selection();
    widget.close();
    widget.swatch.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final swatch = widget.swatch;
    final reason = swatch.disabledReason;
    return Tooltip(
      message: reason == null ? swatch.label : '${swatch.label}: $reason',
      excludeFromSemantics: true,
      child: Semantics(
        label: swatch.label,
        button: true,
        selected: swatch.selected,
        enabled: reason == null,
        hint: reason,
        child: FocusableActionDetector(
          enabled: reason == null,
          mouseCursor: reason == null
              ? SystemMouseCursors.click
              : SystemMouseCursors.forbidden,
          onShowHoverHighlight: (v) => setState(() => _hovered = v),
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => _select(),
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: reason == null ? _select : null,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: swatch.selected
                    ? tokens.accentSoft
                    : (_hovered ? tokens.surfaceSunken : Colors.transparent),
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              foregroundDecoration: _focused
                  ? BoxDecoration(
                      border: Border.all(color: tokens.focusRing, width: 2),
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    )
                  : null,
              alignment: Alignment.center,
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: reason == null ? 1 : 0.4,
                  child: _mark(tokens),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _mark(AppTokens tokens) {
    final swatch = widget.swatch;
    final selected = swatch.selected;
    if (swatch.mark != null) return swatch.mark!;
    if (swatch.color != null) {
      // The ring is a shape cue, so the pick never depends on hue alone.
      return Container(
        width: AppSizes.icon20,
        height: AppSizes.icon20,
        decoration: BoxDecoration(
          color: swatch.color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? tokens.accent : tokens.borderSubtle,
            width: selected ? 2 : 1,
          ),
        ),
        child: selected
            ? Icon(AppIcons.check, size: 12, color: tokens.surfaceBase)
            : null,
      );
    }
    return Container(
      width: AppSpacing.s24,
      height: swatch.lineWidth,
      decoration: BoxDecoration(
        color: selected ? tokens.accent : tokens.textSecondary,
        borderRadius: BorderRadius.circular(swatch.lineWidth!),
      ),
    );
  }
}
