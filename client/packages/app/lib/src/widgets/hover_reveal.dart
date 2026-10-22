// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hover-reveal mechanism a message row uses to show its add-reaction
/// button only on hover, and that the emoji picker and the context menu
/// reuse to stay mounted while their own popup is open.
///
/// Split out of `message_row.dart`, which is where both of those other
/// files were reaching in for [HoverRevealScope] before this existed.
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// How long the list's offset must hold still before hover is allowed again.
const kScrollSettle = Duration(milliseconds: 120);

/// Tracks pointer hover for one subtree.
///
/// Its own widget so a caller like `MessageRow` can stay stateless: a row
/// has a dozen fields, and converting it wholesale to carry one bool would
/// touch every reference in that file.
class HoverReveal extends StatefulWidget {
  const HoverReveal({
    super.key,
    required this.builder,
    this.enterDelay = Duration.zero,
    this.calmWhileScrolling = false,
  });

  /// How long the pointer must rest on the subtree before it reads as hovered.
  /// Leaving is always immediate, so a sweep across rows lights none of them.
  final Duration enterDelay;

  /// Whether hover is withheld while the enclosing list scrolls, and shown
  /// again once it settles if the pointer is still over the subtree.
  final bool calmWhileScrolling;

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
  bool _pointerOver = false;
  bool _hovered = false;
  Timer? _enterTimer;
  ScrollPosition? _position;
  Timer? _settleTimer;
  bool _calm = false;
  bool _pinned = false;
  bool _menuOpen = false;
  bool _focusWithin = false;
  bool _overlayHovered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.calmWhileScrolling) return;
    final next = Scrollable.maybeOf(context)?.position;
    if (next == _position) return;
    _position?.removeListener(_onScrolled);
    _position = next?..addListener(_onScrolled);
  }

  @override
  void dispose() {
    _enterTimer?.cancel();
    _settleTimer?.cancel();
    _position?.removeListener(_onScrolled);
    super.dispose();
  }

  // Watches the offset itself: a mouse wheel moves it without ever marking the position as scrolling.
  void _onScrolled() {
    _calm = true;
    _settleTimer?.cancel();
    _settleTimer = Timer(kScrollSettle, () {
      _calm = false;
      _settleHover();
    });
    if (_pointerOver || _hovered) _settleHover();
  }

  void _onPointer(bool over) {
    _pointerOver = over;
    _settleHover();
  }

  // Leaving and scrolling clear hover at once; entering waits out the intent delay.
  void _settleHover() {
    if (!mounted) return;
    if (!_pointerOver || _calm) {
      _enterTimer?.cancel();
      _enterTimer = null;
      if (_hovered) setState(() => _hovered = false);
      return;
    }
    if (_hovered || _enterTimer != null) return;
    if (widget.enterDelay == Duration.zero) {
      setState(() => _hovered = true);
      return;
    }
    _enterTimer = Timer(widget.enterDelay, () {
      _enterTimer = null;
      if (mounted && _pointerOver && !_calm) setState(() => _hovered = true);
    });
  }

  void _onFocusChange(bool focused) {
    final visible =
        focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (_focusWithin != visible) setState(() => _focusWithin = visible);
  }

  void _pin(bool pinned) {
    if (mounted && _pinned != pinned) setState(() => _pinned = pinned);
  }

  void _reportOverlayHover(bool hovered) {
    if (!mounted || _overlayHovered == hovered) return;
    setState(() => _overlayHovered = hovered);
  }

  void _reportMenuOpen(bool open) {
    if (mounted && _menuOpen != open) setState(() => _menuOpen = open);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onPointer(true),
      onExit: (_) => _onPointer(false),
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
