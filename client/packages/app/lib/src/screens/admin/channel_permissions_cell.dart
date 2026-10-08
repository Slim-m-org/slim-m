// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One tri-state cell of the permissions grid. State is carried by fill and
/// glyph together (solid accent check, tinted danger cross, plain outlined
/// arrow), all from existing accent and danger roles, so it never rests on
/// colour alone.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

enum CellState {
  allow,
  inherit,
  deny;

  /// The state a pending (allow, deny) pair puts [bit] in.
  static CellState resolve(int allow, int deny, int bit) => allow & bit != 0
      ? CellState.allow
      : deny & bit != 0
      ? CellState.deny
      : CellState.inherit;
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

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (fill, border, glyph, icon) = switch (state) {
      CellState.allow => (
        tokens.accentFill,
        tokens.accentFill,
        tokens.accentOn,
        AppIcons.check,
      ),
      CellState.deny => (
        tokens.dangerText.withValues(alpha: 0.14),
        tokens.dangerBorder,
        tokens.dangerText,
        AppIcons.dismiss,
      ),
      CellState.inherit when disabled => (
        Colors.transparent,
        tokens.borderSubtle,
        tokens.textDisabled,
        AppIcons.restrictedChannel,
      ),
      CellState.inherit => (
        tokens.surfaceRaised,
        tokens.borderStrong,
        tokens.textSecondary,
        AppIcons.shapeArrow,
      ),
    };
    final lift = pressed
        ? tokens.textPrimary.withValues(alpha: 0.14)
        : hovered
        ? tokens.textPrimary.withValues(alpha: 0.07)
        : Colors.transparent;
    return AnimatedScale(
      scale: pressed ? 0.92 : 1,
      duration: const Duration(milliseconds: 90),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: _body(tokens, fill, border, lift, icon, glyph),
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
                    border: Border.all(color: tokens.surfaceBase, width: 1.5),
                  ),
                  child: const SizedBox(width: 9, height: 9),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    AppTokens tokens,
    Color fill,
    Color border,
    Color lift,
    IconData icon,
    Color glyph,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: 1.5),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: lift,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Icon(icon, size: 16, color: glyph),
      ),
    );
  }
}

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
  });

  final bool changed;
  final CellState state;
  final bool disabled;
  final String label;
  final VoidCallback onTap;

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
      widget.disabled ? "Inherit; you can't grant this" : 'Inherit from role',
  };

  @override
  Widget build(BuildContext context) => Listener(
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
  );
}
