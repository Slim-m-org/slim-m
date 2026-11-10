// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A focus ring for a child that already owns its own focusability and
/// gestures - typically a bare `InkWell` whose own intrinsic layout (an
/// `Expanded` descendant, say) or non-square shape rules out
/// [FocusableTapTarget], which imposes both a hit-target floor and a
/// shrink-to-content sizing that widget cannot give up.
///
/// The gap and stroke mirror [FocusableTapTarget]'s own ring exactly
/// ([focusRingGap], [focusRingWidth]): reserved whether or not the ring is
/// drawn, so gaining focus never shifts layout, and hugging the wrapped
/// control tightly rather than floating away from what it outlines.
library;

import 'package:flutter/material.dart';

import '../../app_tokens.dart';
import 'focusable_tap_target.dart';

class AppFocusRing extends StatefulWidget {
  const AppFocusRing({super.key, required this.builder, required this.radius});

  /// Builds the interactive content. Wire an interactive descendant's own
  /// focus-change signal straight into the handed callback (`InkWell.
  /// onFocusChange` fits directly) and set that descendant's own
  /// `focusColor` to transparent, or the Material default overlay and this
  /// ring draw at once.
  final Widget Function(
    BuildContext context,
    ValueChanged<bool> onFocusChange,
  ) builder;

  /// The corner radius of the wrapped control itself; the ring's own radius
  /// is derived by adding [focusRingGap], matching [FocusableTapTarget].
  final double radius;

  @override
  State<AppFocusRing> createState() => _AppFocusRingState();
}

class _AppFocusRingState extends State<AppFocusRing> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (focused != _focused) setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.all(focusRingGap),
      decoration: _RingDecoration(
        borderRadius: BorderRadius.circular(widget.radius + focusRingGap),
        border: Border.all(
          color: _focused ? tokens.focusRing : Colors.transparent,
          width: focusRingWidth,
        ),
      ),
      child: widget.builder(context, _onFocusChange),
    );
  }
}

/// The ring's border, which takes no presses so its margin never goes dead.
class _RingDecoration extends BoxDecoration {
  const _RingDecoration({super.border, super.borderRadius});

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      false;
}

/// Focus state for a control that draws its own ring inside its own edge.
///
/// [AppFocusRing] reserves a gap outside the control, which would pull the
/// two halves of an [AppControlWithOptions] apart; a half draws the ring on
/// its chip instead, the way [AppIconButton] does.
class AppInsetFocus extends StatefulWidget {
  const AppInsetFocus({super.key, required this.builder});

  final Widget Function(
    BuildContext context,
    ValueChanged<bool> onFocusChange,
    bool focused,
  ) builder;

  @override
  State<AppInsetFocus> createState() => _AppInsetFocusState();
}

class _AppInsetFocusState extends State<AppInsetFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => widget.builder(
        context,
        (f) => setState(() => _focused = f),
        _focused,
      );
}

/// The ring a half paints over its own chip while focused.
Decoration? appInsetFocusDecoration(
  BuildContext context, {
  required bool focused,
  required BorderRadius borderRadius,
}) {
  if (!focused) return null;
  final tokens = Theme.of(context).extension<AppTokens>()!;
  return BoxDecoration(
    borderRadius: borderRadius,
    border: Border.all(color: tokens.focusRing, width: 2),
  );
}
