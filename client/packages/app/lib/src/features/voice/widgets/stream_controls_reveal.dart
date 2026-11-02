// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When a video's own controls show: while a pointer is over it, while keyboard
/// focus is inside it, or for a few seconds after a finger touches it.
///
/// Unlike `PointerRevealed`, which stays shown where no mouse exists so its
/// label is never lost, a control strip hides until touched: the touch timer
/// is what keeps it reachable on a phone (docs/design/desktop-vs-mobile.md,
/// law 3, every hover affordance has a touch equivalent).
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

/// How long a touch keeps the controls up once nothing holds them.
const Duration kStreamControlsTouchHold = Duration(seconds: 4);

class StreamControlsReveal extends StatefulWidget {
  const StreamControlsReveal({
    super.key,
    required this.builder,
    this.initiallyShown = false,
    this.tapToggles = false,
  });

  /// [hold] is told true while a control needs the strip to stay (a menu is
  /// open, a slider is being dragged) and false when it lets go.
  final Widget Function(
    BuildContext context,
    bool shown,
    ValueChanged<bool> hold,
  )
  builder;

  /// Starts shown and lets the touch timer hide it, as a full screen view does.
  final bool initiallyShown;

  /// A tap on the video hides what a touch showed, and shows it again, instead of only showing.
  final bool tapToggles;

  @override
  State<StreamControlsReveal> createState() => _StreamControlsRevealState();
}

class _StreamControlsRevealState extends State<StreamControlsReveal> {
  bool _hovered = false;
  bool _focused = false;
  bool _touched = false;
  bool _usedTouch = false;
  int _holds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.initiallyShown) _touch(PointerDeviceKind.touch);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _touch(PointerDeviceKind kind) {
    if (kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad) {
      return;
    }
    _usedTouch = true;
    _timer?.cancel();
    _timer = Timer(kStreamControlsTouchHold, () {
      if (mounted) setState(() => _touched = false);
    });
    if (!_touched) setState(() => _touched = true);
  }

  // A pointer leaving ends whatever a finger started, as moving away is a clear sign it is done with.
  void _leave() {
    _timer?.cancel();
    setState(() {
      _hovered = false;
      _touched = false;
    });
  }

  void _toggleTouch() {
    if (!_touched) return _touch(PointerDeviceKind.touch);
    _timer?.cancel();
    setState(() => _touched = false);
  }

  void _hold(bool held) {
    if (!mounted) return;
    final next = (_holds + (held ? 1 : -1)).clamp(0, 1 << 20);
    if (next == _holds) return;
    setState(() => _holds = next);
    if (!held && _holds == 0 && _usedTouch) _touch(PointerDeviceKind.touch);
  }

  // Focus a mouse click left behind does not count: the pointer is over the strip then, and leaving must hide it.
  void _onFocusChange(bool focused) {
    final visible =
        focused &&
        !_hovered &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (_focused != visible) setState(() => _focused = visible);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _hovered || _focused || _touched || _holds > 0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => _leave(),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: widget.tapToggles ? null : (e) => _touch(e.kind),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.tapToggles ? _toggleTouch : null,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: _onFocusChange,
            child: widget.builder(context, shown, _hold),
          ),
        ),
      ),
    );
  }
}
