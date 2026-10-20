// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hover-reveal mechanism a message row uses to show its add-reaction
/// button only on hover, and that the emoji picker and the context menu
/// reuse to stay mounted while their own popup is open.
///
/// Split out of `message_row.dart`, which is where both of those other
/// files were reaching in for [HoverRevealScope] before this existed.
library;

import 'package:flutter/material.dart';

/// Tracks pointer hover for one subtree.
///
/// Its own widget so a caller like `MessageRow` can stay stateless: a row
/// has a dozen fields, and converting it wholesale to carry one bool would
/// touch every reference in that file.
class HoverReveal extends StatefulWidget {
  const HoverReveal({super.key, required this.builder});

  /// [hovered] is true for a mouse over the row or a pinned popup - the
  /// original, narrower purpose (see [HoverRevealScope.pin]'s own doc).
  /// [menuOpen] is [HoverRevealScope.reportMenuOpen]'s own signal: true
  /// whenever this row's context menu is showing, by any gesture, long press
  /// included - the one [hovered] cannot answer, since a long press
  /// deliberately never pins (`ContextMenuRegion._setOpen`'s own doc says
  /// why: touch has no hover-revealed control to keep mounted).
  ///
  /// [focusWithin] is true while keyboard focus is on the subtree, never for
  /// a mouse click that happened to focus something inside it.
  final Widget Function(
    BuildContext context,
    bool hovered,
    bool menuOpen,
    bool focusWithin,
  )
  builder;

  @override
  State<HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<HoverReveal> {
  bool _hovered = false;
  bool _pinned = false;
  bool _menuOpen = false;
  bool _focusWithin = false;
  bool _overlayHovered = false;

  void _onFocusChange(bool focused) {
    final visible =
        focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (_focusWithin != visible) setState(() => _focusWithin = visible);
  }

  void _pin(bool pinned) {
    if (_pinned != pinned) setState(() => _pinned = pinned);
  }

  void _reportOverlayHover(bool hovered) {
    if (!mounted || _overlayHovered == hovered) return;
    setState(() => _overlayHovered = hovered);
  }

  void _reportMenuOpen(bool open) {
    if (_menuOpen != open) setState(() => _menuOpen = open);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: HoverRevealScope(
        pin: _pin,
        reportMenuOpen: _reportMenuOpen,
        reportOverlayHover: _reportOverlayHover,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: _onFocusChange,
          child: widget.builder(
            context,
            _hovered || _pinned || _overlayHovered,
            _menuOpen,
            _focusWithin,
          ),
        ),
      ),
    );
  }
}

/// Lets a hover-revealed control keep itself mounted while it has a popup open.
///
/// Without it, moving the pointer onto the popup leaves the row's [MouseRegion],
/// which unmounts the control and the popup with it - so the thing can be opened
/// and never clicked.
class HoverRevealScope extends InheritedWidget {
  const HoverRevealScope({
    super.key,
    required this.pin,
    required this.reportMenuOpen,
    required this.reportOverlayHover,
    required super.child,
  });

  final ValueChanged<bool> pin;

  /// Reports whether this row's own context menu is open, for a background
  /// highlight rather than for keeping anything mounted; see [HoverReveal]'s
  /// own doc for why this is not the same question [pin] answers.
  final ValueChanged<bool> reportMenuOpen;

  /// A control this row floats outside its own bounds reports the pointer over
  /// it, so reaching it does not read as leaving the row.
  final ValueChanged<bool> reportOverlayHover;

  /// Null outside a hover-revealed subtree, where nothing needs pinning.
  static HoverRevealScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HoverRevealScope>();

  @override
  bool updateShouldNotify(HoverRevealScope oldWidget) =>
      pin != oldWidget.pin ||
      reportMenuOpen != oldWidget.reportMenuOpen ||
      reportOverlayHover != oldWidget.reportOverlayHover;
}
