// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One tri-state cell of the permissions grid. State is carried by fill and
/// glyph together (solid accent check, tinted danger cross, sunken arrow),
/// all from existing accent and danger roles, so it never rests on colour
/// alone. The shapes follow the segmented control: control radius, a sunken
/// trough for the neutral state and a filled chip for the chosen one.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

enum CellState {
  allow,
  inherit,
  deny;

  /// The state a pending (allow, deny) pair puts [bit] in.
  static CellState resolve(int allow, int deny, int bit) {
    if (allow & bit != 0) return CellState.allow;
    return deny & bit != 0 ? CellState.deny : CellState.inherit;
  }
}

/// The painted chip, shared by [Cell] and the legend so the two cannot drift.
class CellChip extends StatelessWidget {
  const CellChip({
    super.key,
    required this.state,
    this.disabled = false,
    this.pressed = false,
    this.hovered = false,
    this.changed = false,
    this.width = 36,
    this.height = 30,
  });

  final CellState state;
  final bool disabled;
  final bool pressed;
  final bool hovered;

  /// Differs from what is saved: marked with a dot so edits read at a glance.
  final bool changed;
  final double width;
  final double height;

  /// Fill, border and glyph for [state], one step stronger while hovered or pressed.
  (Color, Color, Color, IconData) _paint(AppTokens tokens) {
    final active = hovered || pressed;
    return switch (state) {
      CellState.allow => (
        tokens.accentFill,
        active ? tokens.accent : tokens.accentFill,
        tokens.accentOn,
        AppIcons.check,
      ),
      CellState.deny => (
        tokens.dangerText.withValues(alpha: active ? 0.22 : 0.14),
        tokens.dangerBorder,
        tokens.dangerText,
        AppIcons.dismiss,
      ),
      CellState.inherit => (
        active
            ? tokens.surfaceRaised
            : (disabled ? Colors.transparent : tokens.surfaceSunken),
        active ? tokens.borderStrong : tokens.borderSubtle,
        active
            ? tokens.textPrimary
            : (disabled ? tokens.textDisabled : tokens.textSecondary),
        disabled ? AppIcons.restrictedChannel : AppIcons.shapeArrow,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (fill, border, glyph, icon) = _paint(tokens);
    final duration = AppMotion.reduced(context, AppMotion.fast);
    return AnimatedScale(
      scale: pressed ? 0.94 : 1,
      duration: duration,
      curve: AppMotion.entrance,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: duration,
                curve: AppMotion.entrance,
                decoration: BoxDecoration(
                  color: fill,
                  border: Border.all(color: border, width: 1.5),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Icon(icon, size: AppSizes.icon16, color: glyph),
              ),
            ),
            if (changed)
              Positioned(
                top: -3,
                right: -3,
                child: DecoratedBox(
                  key: const ValueKey('cell-changed-dot'),
                  decoration: BoxDecoration(
                    color: tokens.textPrimary,
                    shape: BoxShape.circle,
                    border: Border.all(color: tokens.surfaceRaised, width: 1.5),
                  ),
                  child: const SizedBox(width: 9, height: 9),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// How long a pointer rests on a cell before its tooltip says what it is.
const cellTooltipWait = Duration(milliseconds: 500);

/// One spelling for the inherit state you may not change, in the legend and on the cell.
const inheritBlockedLabel = "Inherit (you can't grant this)";

/// A focusable cell that fills whatever slot the grid gives it, so the touch
/// target is the whole column-by-row area rather than just the chip. [label]
/// names the permission and the column, so a screen reader never hears a bare
/// "Allow".
class Cell extends StatefulWidget {
  const Cell({
    super.key,
    required this.state,
    required this.disabled,
    required this.label,
    required this.onTap,
    this.changed = false,
    this.tooltip,
  });

  final bool changed;
  final CellState state;
  final bool disabled;
  final String label;
  final VoidCallback onTap;

  /// Names the permission and whose column it is, ahead of the state, on hover.
  final String? tooltip;

  @override
  State<Cell> createState() => _CellState();
}

class _CellState extends State<Cell> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  String get _stateLabel => '$_baseLabel${widget.changed ? ', changed' : ''}';

  String get _baseLabel => switch (widget.state) {
    CellState.allow => 'Allow',
    CellState.deny => 'Deny',
    CellState.inherit =>
      widget.disabled ? inheritBlockedLabel : 'Inherit from role',
  };

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '${widget.tooltip ?? widget.label}: $_stateLabel',
    excludeFromSemantics: true,
    waitDuration: cellTooltipWait,
    child: Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: SizedBox.expand(
        child: FocusableTapTarget(
          semanticLabel: '${widget.label}: $_stateLabel',
          onTap: widget.onTap,
          builder: (context, focused, hovered) => CellChip(
            state: widget.state,
            disabled: widget.disabled,
            pressed: _pressed,
            hovered: hovered,
            changed: widget.changed,
          ),
        ),
      ),
    ),
  );
}
