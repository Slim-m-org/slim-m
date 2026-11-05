// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Zoom and pan over a watched share, with a small indicator to reset it.
///
/// The picture is scaled by [ShareZoomController]; annotations are laid over it
/// by their own layer through the same controller, so marks stay normalised to
/// the video and not to the viewport.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/share_zoom_controller.dart';
import 'stream_control_pill.dart';

/// Applies a wheel or trackpad-pinch [event] to [zoom]; true when it was used.
bool applyShareZoomSignal(
  ShareZoomController zoom,
  PointerSignalEvent event,
  Size viewport, {
  bool needsCtrl = false,
}) {
  if (viewport.isEmpty) return false;
  final focal = Offset(
    event.localPosition.dx / viewport.width,
    event.localPosition.dy / viewport.height,
  );
  if (event is PointerScaleEvent) {
    zoom.zoomAt(event.scale, focal);
    return true;
  }
  if (event is! PointerScrollEvent) return false;
  if (needsCtrl && !HardwareKeyboard.instance.isControlPressed) return false;
  final factor = math.exp(-event.scrollDelta.dy * shareZoomWheelRate);
  if (!zoom.zoomed && factor < 1) return false;
  zoom.zoomAt(factor, focal);
  return true;
}

/// Wheel, pinch, keys and drag for [zoom], over [child]; draws nothing of its own but the indicator.
class ShareZoomInput extends StatefulWidget {
  const ShareZoomInput({
    super.key,
    required this.zoom,
    required this.child,
    this.wheelNeedsCtrl = false,
    this.pinch = true,
    this.pillInset = const EdgeInsets.all(AppSpacing.s8),
  });

  final ShareZoomController zoom;
  final Widget child;

  /// True where a plain wheel already belongs to something else, as on the canvas.
  final bool wheelNeedsCtrl;

  /// False where a two-finger gesture already moves something else, as on the canvas.
  final bool pinch;

  /// Keeps the indicator clear of whatever else sits in the bottom-right corner.
  final EdgeInsets pillInset;

  @override
  State<ShareZoomInput> createState() => _ShareZoomInputState();
}

class _ShareZoomInputState extends State<ShareZoomInput> {
  final _focus = FocusNode(debugLabel: 'share zoom');
  final Map<int, Offset> _touches = {};
  double? _pinchGap;
  Size _size = Size.zero;
  bool _keyboardFocused = false;

  ShareZoomController get _zoom => widget.zoom;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_changed);
  }

  @override
  void didUpdateWidget(ShareZoomInput old) {
    super.didUpdateWidget(old);
    if (old.zoom == _zoom) return;
    old.zoom.removeListener(_changed);
    _zoom.addListener(_changed);
  }

  @override
  void dispose() {
    _zoom.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _signal(PointerSignalEvent event) {
    final wheel = event is PointerScrollEvent || event is PointerScaleEvent;
    if (!wheel) return;
    if (event is PointerScrollEvent &&
        widget.wheelNeedsCtrl &&
        !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      applyShareZoomSignal(_zoom, e, _size, needsCtrl: widget.wheelNeedsCtrl);
    });
  }

  void _down(PointerDownEvent event) {
    _focus.requestFocus();
    if (event.kind != PointerDeviceKind.touch) return;
    _touches[event.pointer] = event.localPosition;
    _pinchGap = _touches.length == 2 ? _gap() : null;
  }

  double _gap() => (_touches.values.first - _touches.values.last).distance;

  void _move(PointerMoveEvent event) {
    if (!widget.pinch || !_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.localPosition;
    final before = _pinchGap;
    if (_touches.length != 2 ||
        before == null ||
        before <= 0 ||
        _size.isEmpty) {
      return;
    }
    final now = _gap();
    final mid = (_touches.values.first + _touches.values.last) / 2;
    _zoom.zoomAt(
      now / before,
      Offset(mid.dx / _size.width, mid.dy / _size.height),
    );
    _pinchGap = now;
  }

  void _up(PointerEvent event) {
    _touches.remove(event.pointer);
    _pinchGap = null;
  }

  void _pan(DragUpdateDetails details) {
    if (_touches.length > 1 || _size.isEmpty) return;
    _zoom.panBy(
      Offset(details.delta.dx / _size.width, details.delta.dy / _size.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final zoomed = _zoom.zoomed;
    return LayoutBuilder(
      builder: (context, box) {
        _size = box.biggest;
        return Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) => _zoom.handleKey(event),
          onFocusChange: (focused) => setState(
            () => _keyboardFocused =
                focused &&
                FocusManager.instance.highlightMode ==
                    FocusHighlightMode.traditional,
          ),
          child: Listener(
            onPointerSignal: _signal,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MouseRegion(
                  cursor: zoomed ? SystemMouseCursors.grab : MouseCursor.defer,
                  child: GestureDetector(
                    key: const ValueKey('share-zoom-pan'),
                    behavior: HitTestBehavior.translucent,
                    onPanUpdate: zoomed ? _pan : null,
                    child: widget.child,
                  ),
                ),
                if (_keyboardFocused)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const ValueKey('share-zoom-focus'),
                        decoration: appInsetFocusDecoration(
                          context,
                          focused: true,
                          borderRadius: BorderRadius.zero,
                        )!,
                      ),
                    ),
                  ),
                if (zoomed)
                  Positioned(
                    right: widget.pillInset.right,
                    bottom: widget.pillInset.bottom,
                    child: ShareZoomPill(zoom: _zoom),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The picture itself, scaled and moved by [zoom] and clipped to its own box.
class ShareZoomTransform extends StatelessWidget {
  const ShareZoomTransform({
    super.key,
    required this.zoom,
    required this.child,
  });

  final ShareZoomController zoom;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: zoom,
    builder: (context, child) => LayoutBuilder(
      builder: (context, box) => ClipRect(
        child: Transform(
          key: const ValueKey('share-zoom-transform'),
          transform: Matrix4.identity()
            ..translateByDouble(
              zoom.origin.dx * box.maxWidth,
              zoom.origin.dy * box.maxHeight,
              0,
              1,
            )
            ..scaleByDouble(zoom.scale, zoom.scale, 1, 1),
          child: child,
        ),
      ),
    ),
    child: child,
  );
}

/// A share with zoom, pan and the indicator: the picture and its input in one.
class ShareZoomView extends StatelessWidget {
  const ShareZoomView({
    super.key,
    required this.zoom,
    required this.child,
    this.wheelNeedsCtrl = false,
    this.pinch = true,
    this.pillInset = const EdgeInsets.all(AppSpacing.s8),
  });

  final ShareZoomController zoom;
  final Widget child;
  final bool wheelNeedsCtrl;
  final bool pinch;
  final EdgeInsets pillInset;

  @override
  Widget build(BuildContext context) => ShareZoomInput(
    zoom: zoom,
    wheelNeedsCtrl: wheelNeedsCtrl,
    pinch: pinch,
    pillInset: pillInset,
    child: ShareZoomTransform(zoom: zoom, child: child),
  );
}

/// The zoom level and the way back to fit.
class ShareZoomPill extends StatelessWidget {
  const ShareZoomPill({super.key, required this.zoom});

  final ShareZoomController zoom;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return StreamControlPill(
      padding: const EdgeInsets.only(left: AppSpacing.s8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${zoom.percent}%',
            key: const ValueKey('share-zoom-level'),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: tokens.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          AppIconButton(
            key: const ValueKey('share-zoom-reset'),
            icon: AppIcons.zoomFit,
            semanticLabel: 'Reset zoom',
            tooltip: 'Reset zoom',
            size: AppIconButtonSize.sm,
            onPressed: zoom.reset,
          ),
        ],
      ),
    );
  }
}
