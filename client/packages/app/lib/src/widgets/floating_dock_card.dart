// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one floating card shape a call's controls and a canvas's controls
/// both sit inside, so "the voice bar" and "the canvas toolbar" read as one
/// idea rather than two competing bars.
///
/// [AppRadii.window] and [AppShadows.canvasTile]: both tokens already
/// existed, and neither is invented for this card - the design language's
/// own motion doc rules out a third shadow. An earlier version reached for
/// [AppShadows.float] on the argument that a control surface floating over
/// live content is the same kind of thing as a dragged object; the token
/// set has since drawn a finer line, in [AppShadows.canvasTile]'s own doc
/// and in `canvas_presence_bubble.dart`: a surface that floats
/// *permanently* takes the resting lift, and float's deep picked-up cast
/// belongs only to something transiently above the plane (a menu, a modal,
/// a drag in progress). This dock sits over the call for its whole
/// duration, so it rests.
///
/// **A right-click anywhere on this card is absorbed and does nothing**,
/// the identical no-op `onSecondaryTapUp` `canvas_self_presence_overlay.dart`
/// already uses for the same reason: this card's own padding, its
/// inter-row divider, and any slack the tool strip's scroll viewport leaves
/// past its five buttons are all real background this card paints over
/// content, not buttons - and a right-click landing there would otherwise
/// hit-test straight through to whatever canvas object sits underneath,
/// opening a menu for content the card is visually hiding.
///
/// **`HitTestBehavior.translucent`, not `opaque` - the same choice
/// `CanvasObjectContextMenu`'s own doc already made and explains why.**
/// `RenderProxyBoxWithHitTestBehavior.hitTest` (read from source, not
/// assumed) only stops a hit test from reaching a target visually behind
/// this one when the render object's own `hitTest` call *returns* true, and
/// `opaque`'s `hitTestSelf` returns true unconditionally within its
/// bounds - which would swallow every primary-button pointer landing
/// anywhere on this card, not merely delay or compete for it, before
/// `TapGestureRecognizer.isPointerAllowed` ever gets a say: refusing a
/// pointer only stops *this* card's own tap recognizer from entering the
/// gesture arena, it cannot undo a hit test that already decided nothing
/// behind this card gets the event at all. `translucent`'s `hitTestSelf`
/// returns false, so a point that hits none of this card's own children
/// (its padding, its divider, the tool strip's own slack) returns false
/// from the whole subtree's `hitTest` and the pointer keeps travelling to
/// `CanvasSurface` beneath - while `translucent` still always adds this
/// render object to the hit test result, which is what lets the
/// secondary-tap recognizer see the pointer and absorb a right-click
/// regardless. A point that does land on an actual button is unaffected
/// either way, since that button's own hit test already returns true.
///
/// **`excludeFromSemantics: true` on that same hit-catcher, and it is not
/// about the raw pointer arena at all.** `RawGestureDetector` builds a
/// `TapGestureRecognizer` the moment any tap-family callback is wired,
/// `onSecondaryTapUp` included, and Flutter's own default semantics
/// delegate exposes `SemanticsAction.tap` the instant that recognizer
/// exists - regardless of which specific tap variant it actually carries
/// (`_DefaultSemanticsGestureDelegate._getTapHandler`, read from the
/// framework source). Without the exclusion this card's own full-size
/// background became a second, competing "tappable" ancestor of every real
/// button inside it, and Flutter's semantics action routing did not
/// resolve that competition uniformly: `Mute` still activated correctly
/// through the accessibility tree, `Leave call` silently did not, with no
/// error anywhere - the same shape `canvas_object_context_menu.dart`'s own
/// identical fix already closed for the canvas surface underneath, found
/// here because a real mouse click and a screen-reader-style activation of
/// the same button produced different, silent outcomes for one button and
/// not its neighbour.
///
/// **The card's own inset shrank from [AppSpacing.s8] to [AppSpacing.s4]
/// on every edge and around the inter-row divider**, alongside the call
/// row's own control size (`voice_call_controls.dart`'s own doc comment):
/// the owner reported the whole dock as needing to be "way more compact,"
/// and neither inset ever bounded a touch target, so both were free to
/// tighten without touching the 44dp floor `touch_targets_test.dart` gates.
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
