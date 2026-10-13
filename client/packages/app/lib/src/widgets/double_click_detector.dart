// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A double click or double tap that never delays the single tap beneath it.
///
/// `GestureDetector.onDoubleTap` holds every single tap back until the
/// double-tap window lapses, which would add latency to a call tile's
/// tap-to-open-profile. This watches raw pointers instead.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

const Duration _window = Duration(milliseconds: 300);
const double _slop = 24;

/// Calls [onDoubleClick] once the second primary press lands within the
/// window and slop of the first one that started on [child].
///
/// The second press is read from a global pointer route, not from [child],
/// because the first press may have opened a modal (a profile popover) whose
/// barrier now covers [child] and would swallow it. The call is deferred past
/// the second release so that barrier's own dismissal does not pop whatever
/// [onDoubleClick] pushed.
class DoubleClickDetector extends StatefulWidget {
  const DoubleClickDetector({
    super.key,
    required this.onDoubleClick,
    required this.child,
  });

  final VoidCallback? onDoubleClick;
  final Widget child;

  @override
  State<DoubleClickDetector> createState() => _DoubleClickDetectorState();
}

class _DoubleClickDetectorState extends State<DoubleClickDetector> {
  int? _firstPointer;
  int? _secondPointer;
  Offset _firstAt = Offset.zero;
  Duration _firstTime = Duration.zero;
  Timer? _expiry;
  bool _routed = false;

  @override
  void dispose() {
    _disarm();
    super.dispose();
  }

  void _disarm() {
    _expiry?.cancel();
    _expiry = null;
    _firstPointer = null;
    _secondPointer = null;
    if (!_routed) return;
    _routed = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobal);
  }

  bool _isPrimaryDown(PointerEvent e) =>
      e is PointerDownEvent &&
      (e.kind != PointerDeviceKind.mouse || e.buttons == kPrimaryButton);

  void _onTileDown(PointerDownEvent e) {
    if (widget.onDoubleClick == null || _firstPointer != null) return;
    if (!_isPrimaryDown(e)) return;
    _firstPointer = e.pointer;
    _firstAt = e.position;
    _firstTime = e.timeStamp;
    _expiry = Timer(_window, _disarm);
    _routed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobal);
  }

  void _onGlobal(PointerEvent e) {
    if (e.pointer == _firstPointer) return;
    if (e.pointer == _secondPointer) {
      if (e is PointerUpEvent) {
        _disarm();
        Timer.run(() {
          if (mounted) widget.onDoubleClick?.call();
        });
      } else if (e is PointerCancelEvent) {
        _disarm();
      }
      return;
    }
    if (!_isPrimaryDown(e) || _secondPointer != null) return;
    final close = (e.position - _firstAt).distance <= _slop;
    if (close && e.timeStamp - _firstTime <= _window) {
      _secondPointer = e.pointer;
      _expiry?.cancel();
    } else {
      _disarm();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onTileDown,
    child: widget.child,
  );
}
