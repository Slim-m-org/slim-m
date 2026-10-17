// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one floating card both the call controls and the canvas controls sit
/// in, so they read as one idea. It rests at [AppShadows.canvasTile] because
/// it floats for the whole call, not transiently.
///
/// A right-click on its background is absorbed so it never opens a menu for
/// the canvas object hidden underneath; the catcher is translucent so a
/// left-button stroke still reaches the canvas, and excluded from semantics
/// because a second tappable ancestor broke screen-reader activation of
/// Leave call.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// A floating, rounded, shadowed card holding one or more rows of controls,
/// each row separated by a hairline divider.
///
/// Never full-bleed: the caller positions this with margin on every side (see
/// `canvas_call_dock.dart` and `voice_screen.dart`'s own placement), which is
/// what makes it read as floating over content rather than as a bar the
/// content stops above. [rows] is a list rather than one child because a
/// call's controls and a canvas's controls are drawn as genuinely separate
/// rows at touch width - see `CanvasCallDock`'s own doc for why - and a
/// single [Column] here keeps the divider between them in one place instead
/// of every caller redrawing it.
class FloatingDockCard extends StatelessWidget {
  const FloatingDockCard({
    super.key,
    required this.rows,
    this.trailing,
    this.hugsWidth = false,
  });

  /// Sizes the card to its widest row. The hairlines between rows would
  /// otherwise stretch it to the pane; off for a card holding a scroll strip,
  /// which has no intrinsic width.
  final bool hugsWidth;

  final List<Widget> rows;

  /// Sits at the end of the last row, after a divider, so the far edge of
  /// the card is always the same control (leave, in a call).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final divided = <Widget>[];
    final trailing = this.trailing;
    final rows = [
      for (var i = 0; i < this.rows.length; i++)
        if (trailing != null && i == this.rows.length - 1)
          _withTrailing(this.rows[i], trailing)
        else
          this.rows[i],
    ];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        divided.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: Divider(height: 1, thickness: 1, color: tokens.borderSubtle),
          ),
        );
      }
      divided.add(hugsWidth ? Center(child: rows[i]) : rows[i]);
    }
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: hugsWidth
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.center,
      children: divided,
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // A no-op, not an omission: see this file's own library doc for why a right-click here must never reach a canvas object menu beneath.
      onSecondaryTapUp: (_) {},
      // Load-bearing, not tidiness - see this file's own library doc.
      excludeFromSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s12,
          vertical: AppSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadii.window),
          border: Border.all(color: tokens.borderSubtle),
          boxShadow: AppShadows.canvasTile,
        ),
        child: AnimatedSize(
          duration: AppMotion.reducedSize(context, AppMotion.base),
          curve: AppMotion.entrance,
          child: hugsWidth ? IntrinsicWidth(child: column) : column,
        ),
      ),
    );
  }

  /// The top edge of the dock card around [context], in [overlay]'s space, or
  /// null when [context] is not inside one. Menus that open above a dock
  /// control anchor here, so they clear the card rather than covering its top.
  static double? topEdgeOf(BuildContext context, RenderBox overlay) {
    RenderBox? card;
    context.visitAncestorElements((element) {
      if (element.widget is! FloatingDockCard) return true;
      card = element.renderObject as RenderBox?;
      return false;
    });
    return card?.localToGlobal(Offset.zero, ancestor: overlay).dy;
  }

  static Widget _withTrailing(Widget row, Widget trailing) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: row),
      const SizedBox(width: AppSpacing.s4),
      const DockVerticalDivider(),
      const SizedBox(width: AppSpacing.s4),
      trailing,
    ],
  );
}

/// The 1x24 hairline between groups of controls in one row.
class DockVerticalDivider extends StatelessWidget {
  const DockVerticalDivider({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: AppSpacing.s24,
    child: VerticalDivider(
      width: 1,
      thickness: 1,
      color: Theme.of(context).extension<AppTokens>()!.borderSubtle,
    ),
  );
}
