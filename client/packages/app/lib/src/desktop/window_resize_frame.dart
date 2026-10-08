// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hand-rolled resize hit-test border decision 0012 named as a real cost
/// of going frameless: eight thin regions, one per edge and corner, each
/// starting a native [DesktopWindowPort.startResizing] drag on pointer-down
/// and showing the matching platform resize cursor on hover - the border a
/// decorated window gets for free from the window manager, gone the moment
/// [DesktopWindowPort.hideTitleBar] strips the native frame.
///
/// Mounted only while [DesktopWindowShell.frameless] is true, the same gate
/// [TitleBar] itself is mounted on - a capability check tied to the
/// frameless shell, never a `Platform.isX` branch or a width breakpoint, per
/// `docs/design/desktop-vs-mobile.md`.
///
/// This never renders during the splash, and needs no separate check to say
/// so: `DesktopChrome` - the only place that mounts this frame - only ever
/// builds once `appReadyProvider` is true, and `main.dart`'s own handoff
/// sequence already restores `setResizable(true)` and the real window
/// geometry (`DesktopWindowShell.prepareHandoff`) before that flip happens.
/// `frameless` itself actually turns true earlier, during
/// `DesktopWindowShell.lockSplashChrome` while the splash is still up and
/// deliberately unresizable - but `StartupApp` renders on its own, with no
/// `DesktopChrome` in its tree, so that earlier flip mounts nothing here
/// either.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'desktop_window_port.dart';

/// Thickness of every edge band and the side length of every corner square,
/// within decision 0012's own 4-8dp range for a hand-rolled hit-test
/// border. Checked against the title bar's own real geometry rather than
/// picked blind: a 26dp `AppIconButtonSize.sm` control centered in the
/// 40dp bar sits 7dp clear of its top edge, so a 6dp band never covers a
/// control's own hit area.
const double kWindowResizeHandleThickness = 6;

class WindowResizeFrame extends StatefulWidget {
  const WindowResizeFrame({super.key, required this.port});

  final DesktopWindowPort port;

  @override
  State<WindowResizeFrame> createState() => _WindowResizeFrameState();
}

class _WindowResizeFrameState extends State<WindowResizeFrame> {
  bool _maximized = false;
  bool _fullScreen = false;
  StreamSubscription<DesktopWindowEventKind>? _subscription;

  @override
  void initState() {
    super.initState();
    unawaited(_syncRunState());
    _subscription = widget.port.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _syncRunState() async {
    try {
      final maximized = await widget.port.isMaximized();
      final fullScreen = await widget.port.isFullScreen();
      if (!mounted) return;
      setState(() {
        _maximized = maximized;
        _fullScreen = fullScreen;
      });
    } catch (_) {
      // An early-startup plugin failure leaves the frame active by default.
    }
  }

  void _onEvent(DesktopWindowEventKind event) {
    switch (event) {
      case DesktopWindowEventKind.maximize:
        setState(() => _maximized = true);
      case DesktopWindowEventKind.unmaximize:
        setState(() => _maximized = false);
      case DesktopWindowEventKind.fullScreen:
        setState(() => _fullScreen = true);
      case DesktopWindowEventKind.leaveFullScreen:
        setState(() => _fullScreen = false);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // A maximized or full-screen window has no edge left for a band to grab.
    if (_maximized || _fullScreen) return const SizedBox.shrink();

    return ResizeHandles(onStart: widget.port.startResizing);
  }
}

/// The eight hit regions on their own, so a window without a
/// [DesktopWindowPort] (the pop-out) mounts the same border.
class ResizeHandles extends StatelessWidget {
  const ResizeHandles({super.key, required this.onStart});

  final void Function(ResizeEdge edge) onStart;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (final spec in _handleSpecs)
          Positioned(
            top: spec.top,
            bottom: spec.bottom,
            left: spec.left,
            right: spec.right,
            width: spec.width,
            height: spec.height,
            child: _ResizeHandle(
              key: ValueKey(spec.edge),
              onStart: onStart,
              edge: spec.edge,
              cursor: spec.cursor,
            ),
          ),
      ],
    );
  }
}

/// One row per handle: `null` for an inset means "flush with that side",
/// and `t`/`0` picks the band's own thickness versus the true edge - edges
/// run only between the corners (inset by [kWindowResizeHandleThickness] at
/// both ends) so a corner and its adjoining edges never overlap. Corners win
/// by this construction, not by z-order.
class _HandleSpec {
  const _HandleSpec(
    this.edge,
    this.cursor, {
    this.top,
    this.bottom,
    this.left,
    this.right,
    this.width,
    this.height,
  });

  final ResizeEdge edge;
  final MouseCursor cursor;
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;
  final double? width;
  final double? height;
}

const double _t = kWindowResizeHandleThickness;

final List<_HandleSpec> _handleSpecs = [
  _HandleSpec(
    ResizeEdge.top,
    SystemMouseCursors.resizeUpDown,
    top: 0,
    left: _t,
    right: _t,
    height: _t,
  ),
  _HandleSpec(
    ResizeEdge.bottom,
    SystemMouseCursors.resizeUpDown,
    bottom: 0,
    left: _t,
    right: _t,
    height: _t,
  ),
  _HandleSpec(
    ResizeEdge.left,
    SystemMouseCursors.resizeLeftRight,
    left: 0,
    top: _t,
    bottom: _t,
    width: _t,
  ),
  _HandleSpec(
    ResizeEdge.right,
    SystemMouseCursors.resizeLeftRight,
    right: 0,
    top: _t,
    bottom: _t,
    width: _t,
  ),
  _HandleSpec(
    ResizeEdge.topLeft,
    SystemMouseCursors.resizeUpLeftDownRight,
    top: 0,
    left: 0,
    width: _t,
    height: _t,
  ),
  _HandleSpec(
    ResizeEdge.topRight,
    SystemMouseCursors.resizeUpRightDownLeft,
    top: 0,
    right: 0,
    width: _t,
    height: _t,
  ),
  _HandleSpec(
    ResizeEdge.bottomLeft,
    SystemMouseCursors.resizeUpRightDownLeft,
    bottom: 0,
    left: 0,
    width: _t,
    height: _t,
  ),
  _HandleSpec(
    ResizeEdge.bottomRight,
    SystemMouseCursors.resizeUpLeftDownRight,
    bottom: 0,
    right: 0,
    width: _t,
    height: _t,
  ),
];

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    super.key,
    required this.onStart,
    required this.edge,
    required this.cursor,
  });

  final void Function(ResizeEdge edge) onStart;
  final ResizeEdge edge;
  final MouseCursor cursor;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onStart(edge),
      child: const SizedBox.expand(),
    ),
  );
}
