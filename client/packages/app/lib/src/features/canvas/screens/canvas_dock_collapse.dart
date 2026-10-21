// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets the canvas dock tuck away while the pane is fullscreen, leaving a
/// half-sphere handle at the bottom edge that brings it back.
///
/// A pointer reveals the dock by moving toward the bottom edge; a finger taps
/// the handle, which is the named equivalent of that hover (docs/design/
/// desktop-vs-mobile.md, law 3). Outside fullscreen it is a plain pass-through.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/hover_reveal.dart';

/// How close to the bottom edge a pointer must come to reveal a collapsed dock.
const canvasDockRevealZone = 56.0;

/// How long the dock lingers after the pointer leaves, so crossing a popup does not snap it shut.
const canvasDockHideDelay = Duration(milliseconds: 500);

const _handleSize = Size(64, 22);

/// What a folded dock still occupies at the bottom edge.
const canvasDockHandleHeight = 22.0;

class CanvasDockCollapse extends StatefulWidget {
  const CanvasDockCollapse({
    super.key,
    required this.collapsible,
    required this.builder,
  });

  final bool collapsible;

  /// Builds the dock, told whether it is showing so it can report its extent.
  final Widget Function(BuildContext context, bool revealed) builder;

  @override
  State<CanvasDockCollapse> createState() => _CanvasDockCollapseState();
}

class _CanvasDockCollapseState extends State<CanvasDockCollapse> {
  bool _pinned = false;
  bool _hovering = false;
  int _popupPins = 0;
  bool _focusWithin = false;
  Timer? _hideTimer;

  bool get _revealed =>
      !widget.collapsible ||
      _pinned ||
      _hovering ||
      _popupPins > 0 ||
      _focusWithin;

  @override
  void didUpdateWidget(covariant CanvasDockCollapse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsible && !widget.collapsible) {
      _hideTimer?.cancel();
      _pinned = false;
      _hovering = false;
      _popupPins = 0;
      _focusWithin = false;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _enter() {
    _hideTimer?.cancel();
    if (!_hovering) setState(() => _hovering = true);
  }

  void _leave() {
    _hideTimer?.cancel();
    _hideTimer = Timer(canvasDockHideDelay, () {
      if (mounted) setState(() => _hovering = false);
    });
  }

  // Counted, as a popup's pointer is outside this region and a second opening as the first closes must not unpin the dock.
  void _pinForPopup(bool open) {
    if (!mounted) return;
    final next = (_popupPins + (open ? 1 : -1)).clamp(0, 1 << 20);
    if (next == _popupPins) return;
    setState(() => _popupPins = next);
  }

  void _onFocusChange(bool focused) {
    final visible =
        focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (_focusWithin != visible) setState(() => _focusWithin = visible);
  }

  // A press on a hover-revealed dock pins it open; only a pinned one folds.
  void _toggle() {
    _hideTimer?.cancel();
    setState(() {
      _hovering = false;
      _pinned = !_pinned;
    });
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _revealed;
    final dock = ExcludeFocus(
      excluding: !revealed,
      child: ExcludeSemantics(
        excluding: !revealed,
        child: IgnorePointer(
          ignoring: !revealed,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: _onFocusChange,
            child: widget.builder(context, revealed),
          ),
        ),
      ),
    );
    return HoverRevealScope(
      pin: _pinForPopup,
      reportMenuOpen: (_) {},
      reportOverlayHover: (_) {},
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: widget.collapsible ? (_) => _enter() : null,
        onExit: widget.collapsible ? (_) => _leave() : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: widget.collapsible ? canvasDockRevealZone : 0,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.collapsible)
                  // Room above the slim handle at touch density, so its hit area reaches a full 44.
                  Padding(
                    padding: EdgeInsets.only(
                      top: AppTouchTargets.of(context)
                          ? AppSizes.rowTouch - canvasDockHandleHeight
                          : 0,
                    ),
                    child: _DockHandle(revealed: revealed, onPressed: _toggle),
                  ),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: revealed ? 1 : 0),
                  duration: AppMotion.reduced(context, AppMotion.base),
                  curve: Curves.easeOutCubic,
                  child: dock,
                  builder: (context, factor, child) => ClipRect(
                    child: Align(
                      alignment: Alignment.topCenter,
                      heightFactor: factor,
                      child: child,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps the enclosing dock revealed for as long as a popup it opened is mounted.
class CanvasDockPopupPin extends StatefulWidget {
  const CanvasDockPopupPin({super.key, required this.child});

  final Widget child;

  @override
  State<CanvasDockPopupPin> createState() => _CanvasDockPopupPinState();
}

class _CanvasDockPopupPinState extends State<CanvasDockPopupPin> {
  HoverRevealScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = HoverRevealScope.maybeOf(context);
    if (_scope == null && scope != null) {
      scheduleMicrotask(() => scope.pin(true));
    }
    _scope = scope;
  }

  @override
  void dispose() {
    final scope = _scope;
    if (scope != null) scheduleMicrotask(() => scope.pin(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DockHandle extends StatefulWidget {
  const _DockHandle({required this.revealed, required this.onPressed});

  final bool revealed;
  final VoidCallback onPressed;

  @override
  State<_DockHandle> createState() => _DockHandleState();
}

class _DockHandleState extends State<_DockHandle> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = widget.revealed ? 'Hide controls' : 'Show controls';
    // Outermost, so the reach into the room above is not cut off by the semantics and tooltip boxes.
    return AppTouchHitArea(
      alignment: Alignment.bottomCenter,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: widget.onPressed,
        child: Tooltip(
          message: label,
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.click,
            onShowFocusHighlight: (v) => setState(() => _focused = v),
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onPressed();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: Container(
                width: _handleSize.width,
                height: _handleSize.height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tokens.surfaceRaised,
                  border: Border.all(
                    color: _focused ? tokens.focusRing : tokens.borderSubtle,
                  ),
                  boxShadow: AppShadows.canvasTile,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(_handleSize.height),
                  ),
                ),
                child: Icon(
                  widget.revealed ? AppIcons.chevronDown : AppIcons.chevronUp,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
