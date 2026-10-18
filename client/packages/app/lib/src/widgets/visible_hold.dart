// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Holds a resource only while a widget is mounted and its route is shown.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Calls [acquire] when it is mounted under an active [TickerMode] and
/// [release] when it unmounts or a route covers it, always in that order and
/// never twice in a row. A covered route keeps its widgets mounted, so mounted
/// alone does not mean seen.
class VisibleHold extends StatefulWidget {
  const VisibleHold({
    super.key,
    required this.acquire,
    required this.release,
    required this.child,
    this.active = true,
  });

  /// False holds nothing even while shown, for a meter that is not drawn.
  final bool active;

  final VoidCallback acquire;
  final VoidCallback release;
  final Widget child;

  @override
  State<VisibleHold> createState() => _VisibleHoldState();
}

class _VisibleHoldState extends State<VisibleHold> {
  late final VoidCallback _acquire = widget.acquire;
  late final VoidCallback _release = widget.release;
  bool _wanted = false;
  bool _shown = true;
  bool _held = false;
  bool _queued = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shown = TickerMode.valuesOf(context).enabled;
    _update();
  }

  @override
  void didUpdateWidget(VisibleHold oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() {
    _wanted = _shown && widget.active;
    _settle();
  }

  @override
  void dispose() {
    _wanted = false;
    _settle();
    super.dispose();
  }

  // Deferred so provider state is never changed while the tree is building or tearing down.
  void _settle() {
    if (_queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_wanted == _held) return;
      _held = _wanted;
      _held ? _acquire() : _release();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
