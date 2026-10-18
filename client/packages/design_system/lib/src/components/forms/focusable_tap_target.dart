// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A focusable, tappable control shared by the form widgets in this
/// directory.
///
/// Every one of them needs the same three things: a focus node it can own or
/// receive, keyboard activation on Enter and Space, and a focus ring drawn
/// from `tokens.focusRing` that sits just outside the control rather than
/// reusing the accent border a selected or active state already draws.
/// Building that once here is what keeps several sibling widgets from
/// drifting into slightly different versions of the same behaviour.
///
/// The ring hugs the visible control tightly; the hit-target floor grows the
/// invisible tappable margin around it instead, so a small chip on a touch
/// layout gets a bigger tap area without a ring that floats away from what it is
/// meant to outline.
///
/// The ring only paints for [FocusHighlightMode.traditional] (keyboard or a
/// platform that reports it), the same distinction FocusableActionDetector
/// already draws for AppListRow's own focus ring. A plain tap already
/// requests real focus, for Enter/Space activation and screen-reader state,
/// but painting a ring for that too would show one on every ordinary tap,
/// floating outside a control that may have nothing but its own content's
/// height to spare.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../touch_targets.dart';

/// The gap between a control's edge and its focus ring, and the ring's own
/// stroke width. There is no dedicated token for either: both are reserved
/// space kept constant whether or not the ring is drawn, so gaining focus
/// never shifts layout.
const double focusRingGap = 2;
const double focusRingWidth = 2;

/// The hit-target floor this subtree is at.
///
/// Reads [AppTouchTargets], which is where the width rule the form controls
/// always applied now lives, so a form control, the row it sits in and the
/// button beside it cannot end up at three different densities.
double minHitExtent(BuildContext context) =>
    AppTouchTargets.of(context) ? AppSizes.rowTouch : AppSizes.rowPointer;

typedef FocusableTapBuilder = Widget Function(
  BuildContext context,
  bool focused,
  bool hovered,
);

class FocusableTapTarget extends StatefulWidget {
  const FocusableTapTarget({
    super.key,
    required this.builder,
    this.onTap,
    this.focusNode,
    this.semanticLabel,
    this.enabled = true,
    this.isButton = true,
    this.selected,
    this.toggled,
    this.ringRadius = AppRadii.control,
  });

  final FocusableTapBuilder builder;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final String? semanticLabel;
  final bool enabled;
  final bool isButton;
  final bool? selected;
  final bool? toggled;
  final double ringRadius;

  @override
  State<FocusableTapTarget> createState() => _FocusableTapTargetState();
}

class _FocusableTapTargetState extends State<FocusableTapTarget> {
  late final FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChange);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChange);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  // A mode change alone (no focus change) still needs a rebuild, so the ring catches up once input switches to a keyboard.
  void _onHighlightModeChange(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  void _activate() {
    if (widget.enabled) widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final content = widget.builder(context, _focused, _hovered);

    // Real focus (Enter/Space, screen readers) is unaffected; only the paint below reads the highlight mode.
    final showRing = _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

    // The ring hugs the control tightly; the hit-target floor below grows the
    // invisible margin instead. See the library doc at the top of the file.
    final ring = Container(
      padding: const EdgeInsets.all(focusRingGap),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.ringRadius + focusRingGap),
        border: Border.all(
          color: showRing ? tokens.focusRing : Colors.transparent,
          width: focusRingWidth,
        ),
      ),
      child: content,
    );

    final hitExtent = minHitExtent(context);

    return Semantics(
      button: widget.isButton,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      selected: widget.selected,
      toggled: widget.toggled,
      onTap: widget.enabled ? _activate : null,
      child: Focus(
        focusNode: _focusNode,
        canRequestFocus: widget.enabled,
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            _activate();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled
                ? () {
                    _focusNode.requestFocus();
                    _activate();
                  }
                : null,
            child: Container(
              constraints:
                  BoxConstraints(minWidth: hitExtent, minHeight: hitExtent),
              // Size factors, not Container's alignment: an Align with no
              // factor expands to its constraints, so a chip in a Wrap took
              // the whole line instead of gaining a 44pt hit box.
              child: Align(
                alignment: Alignment.center,
                widthFactor: 1,
                heightFactor: 1,
                // Keeps the click cursor over text inside a SelectionArea.
                child: SelectionContainer.disabled(child: ring),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
