// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One way to ask for a modal, presented as whatever the window can carry.
///
/// A bottom sheet is a phone affordance: it sits against the edge a thumb can
/// reach, and its drag handle means something to a thumb. On a desktop window
/// it reads as a phone screen pasted along the bottom of a monitor, offers a
/// handle a mouse cannot usefully drag, and gets cut off by the bottom of the
/// window when the content is tall. Every modal in the app was one.
///
/// So the same call gives a sheet on a phone and a centred dialog on anything
/// wider, and the caller does not choose: the window does.
///
/// [showModalBottomSheet] and [showDialog] each drive their own entrance and
/// exit with a plain [AnimationController] Flutter creates internally, keyed
/// to the platform's own reduce-motion accessibility feature - never to this
/// app's [MotionOverride], which only ever reaches [MediaQuery] and cannot
/// touch a controller Flutter owns. [AnimationStyle.noAnimation] is the
/// documented escape hatch for exactly this case, so every sheet and dialog
/// this function opens honours the in-app setting rather than only the OS
/// one it happens to inherit for free.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import 'in_window_dialog.dart';

/// How wide a dialog is allowed to get, when it is one.
///
/// A form does not become more readable by growing with the monitor, and a
/// modal that spans a wide screen stops reading as a modal at all.
const double kSheetMaxWidth = 460;

/// The gap between a dialog's top edge and its content.
///
/// A bottom sheet gets its top gap from the drag handle, so its content pads
/// the sides and bottom only. The dialog has no handle, so it supplies this
/// instead, once, and content never pads its own top edge.
const double kSheetDialogTopInset = AppSpacing.s16;

/// Shows [builder] as a bottom sheet on a phone and a dialog on a desktop.
///
/// [maxWidth] widens the dialog for content that genuinely needs it, a grid of
/// emoji rather than a form. [scrolls] says the content already scrolls, so it
/// is given a bounded height and left to manage it; the default wraps it,
/// which is right for the columns most of these are. [bare] is for content
/// that already draws its own surface, an [AppMenu] being the case: without it
/// the dialog's panel and the menu's panel nest, one border inside another.
///
/// The bottom-sheet branch wraps [builder] in its own `SafeArea(top: false)`,
/// so a sheet's own bottom-most content - routinely a primary action button -
/// is never left sitting under a phone's home indicator: nothing about
/// `showModalBottomSheet` reserves that inset on its own, and only one caller
/// out of a dozen remembered to. A caller that already wraps its own content
/// in one nests harmlessly, since the inner `SafeArea` then has nothing left
/// to reserve.
///
/// It also pads the content by the on-screen keyboard and, unless [scrolls],
/// wraps it in a scroll view, so a form that is taller than the space the
/// keyboard leaves scrolls rather than overflowing. A caller pads its sides
/// and bottom only, never the keyboard inset. The dialog branch needs neither:
/// a desktop window has no keyboard to cover it.
///
/// The dialog branch wraps the content in `Semantics(container: true,
/// explicitChildNodes: true)`, as `AlertDialog` wraps its own. A dialog route
/// names itself from every descendant that forms no semantics node of its
/// own; content inside a scroll region is safe, since the scrollable is a
/// boundary, but a heading or action button pinned beside it (the layout
/// [scrolls] exists for) was merged into the route's label and lost its tap
/// action - unreachable by a screen reader, and by the e2e harness that drives
/// the app through the same tree. `explicitChildNodes` keeps every child a
/// node.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxWidth = kSheetMaxWidth,
  bool scrolls = false,
  bool bare = false,
}) {
  // Only overridden when reduced, so a full-motion viewer keeps Flutter's own stock timing rather than this app's own scale.
  final noAnimation =
      AppMotion.isReduced(context) ? AnimationStyle.noAnimation : null;
  if (MediaQuery.sizeOf(context).width < kCompactWidth) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: noAnimation,
      builder: (context) => SafeArea(
        top: false,
        child:
            _KeyboardInset(scrolls: scrolls, child: Builder(builder: builder)),
      ),
    );
  }
  return showInWindowDialog<T>(
    context: context,
    animationStyle: noAnimation,
    builder: (context) => _SheetDialog(
      maxWidth: maxWidth,
      scrolls: scrolls,
      bare: bare,
      child: Builder(builder: builder),
    ),
  );
}

class _KeyboardInset extends StatelessWidget {
  const _KeyboardInset({required this.scrolls, required this.child});

  final bool scrolls;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: scrolls ? child : SingleChildScrollView(child: child),
    );
  }
}

class _SheetDialog extends StatelessWidget {
  const _SheetDialog({
    required this.maxWidth,
    required this.scrolls,
    required this.bare,
    required this.child,
  });

  final double maxWidth;
  final bool scrolls;
  final bool bare;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Never taller than the window, whatever the content asks for: the bottom
    // sheet's failure was being cut off by an edge it could not see.
    final ceiling = MediaQuery.sizeOf(context).height * 0.85;

    return Dialog(
      backgroundColor: bare ? Colors.transparent : tokens.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: bare ? 0 : null,
      insetPadding: const EdgeInsets.all(AppSpacing.s24),
      shape: bare
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.card),
              side: BorderSide(color: tokens.borderSubtle),
            ),
      // explicitChildNodes: see the route-naming paragraph in showAppSheet's doc.
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: ceiling),
          child: Padding(
            padding: EdgeInsets.only(top: bare ? 0 : kSheetDialogTopInset),
            child: scrolls ? child : SingleChildScrollView(child: child),
          ),
        ),
      ),
    );
  }
}
