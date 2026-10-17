// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One tab stop per message row, with the row's own controls on the arrow keys.
///
/// A row used to put its avatar, its name and every hover-toolbar button into
/// the tab order, about eight stops a message, so a keyboard user reached five
/// messages in 45 presses and the composer was hundreds of stops away.
///
/// Those controls are chrome around the message and all of them are also in
/// the row's context menu (or, for the profile, one arrow step from the row),
/// so Tab now lands on the row alone. Right and Left walk the controls in
/// reading order, Escape returns to the row, and Tab or Shift+Tab from a
/// control leaves the row for the neighbouring stop. Controls inside the
/// message body (links, reactions, buttons) keep their ordinary stops.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}

class _ReturnToRowIntent extends Intent {
  const _ReturnToRowIntent();
}

const Map<ShortcutActivator, Intent> _shortcuts = {
  SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
  SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
  SingleActivator(LogicalKeyboardKey.escape): _ReturnToRowIntent(),
};

/// Owns the row's focus node and the ordered set of controls that ride it.
///
/// Wrap the row's context-menu region in this and hand [MessageRowRoving.rowNode]
/// down as the region's `focusNode`. Controls opt in with [RovingStop].
class MessageRowRoving extends StatefulWidget {
  const MessageRowRoving({super.key, required this.builder});

  final Widget Function(BuildContext context, FocusNode rowNode) builder;

  @override
  State<MessageRowRoving> createState() => _MessageRowRovingState();
}

class _MessageRowRovingState extends State<MessageRowRoving> {
  final _rowNode = FocusNode(debugLabel: 'message row');
  final _stops = <FocusNode>[];

  @override
  void dispose() {
    _rowNode.dispose();
    super.dispose();
  }

  void _register(FocusNode node) => _stops.add(node);

  void _unregister(FocusNode node) => _stops.remove(node);

  bool get _onAControl {
    final focus = FocusManager.instance.primaryFocus;
    return focus != null && _stops.contains(focus);
  }

  bool get _onTheRow => FocusManager.instance.primaryFocus == _rowNode;

  List<FocusNode> _inReadingOrder() {
    final live = _stops.where((n) => n.context != null && n.canRequestFocus);
    return live.toList()..sort((a, b) {
      final byLeft = a.rect.left.compareTo(b.rect.left);
      return byLeft != 0 ? byLeft : a.rect.top.compareTo(b.rect.top);
    });
  }

  void _step(int delta) {
    final stops = _inReadingOrder();
    final here = _onTheRow
        ? -1
        : stops.indexOf(FocusManager.instance.primaryFocus!);
    final target = here + delta;
    if (target < -1 || target >= stops.length) return;
    (target == -1 ? _rowNode : stops[target]).requestFocus();
  }

  bool _leaveRow({required bool forward}) {
    if (_onAControl) _rowNode.requestFocus();
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    return forward ? focus.nextFocus() : focus.previousFocus();
  }

  @override
  Widget build(BuildContext context) {
    return _RovingScope(
      register: _register,
      unregister: _unregister,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _StepIntent: _WhenFocused<_StepIntent>(
            () => _onTheRow || _onAControl,
            (intent) => _step(intent.delta),
          ),
          _ReturnToRowIntent: _WhenFocused<_ReturnToRowIntent>(
            () => _onAControl,
            (_) => _rowNode.requestFocus(),
          ),
          // Always enabled: a disabled action here shadows the app's own Tab handling.
          NextFocusIntent: CallbackAction<NextFocusIntent>(
            onInvoke: (_) => _leaveRow(forward: true),
          ),
          PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
            onInvoke: (_) => _leaveRow(forward: false),
          ),
        },
        child: Shortcuts(
          shortcuts: _shortcuts,
          child: Builder(
            builder: (context) => widget.builder(context, _rowNode),
          ),
        ),
      ),
    );
  }
}

class _WhenFocused<T extends Intent> extends Action<T> {
  _WhenFocused(this._enabled, this._run);

  final bool Function() _enabled;
  final void Function(T intent) _run;

  @override
  bool isEnabled(T intent) => _enabled();

  @override
  Object? invoke(T intent) {
    _run(intent);
    return null;
  }
}

class _RovingScope extends InheritedWidget {
  const _RovingScope({
    required this.register,
    required this.unregister,
    required super.child,
  });

  final void Function(FocusNode) register;
  final void Function(FocusNode) unregister;

  static _RovingScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_RovingScope>();

  @override
  bool updateShouldNotify(_RovingScope oldWidget) => false;
}

/// A control that takes part in its row's arrow-key walk instead of the tab
/// order. Outside a [MessageRowRoving] it is an ordinary focusable control.
///
/// [builder] must hand the node to the control's own `focusNode`.
class RovingStop extends StatefulWidget {
  const RovingStop({super.key, required this.builder});

  final Widget Function(BuildContext context, FocusNode node) builder;

  @override
  State<RovingStop> createState() => _RovingStopState();
}

class _RovingStopState extends State<RovingStop> {
  final _node = FocusNode(debugLabel: 'row control');
  _RovingScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = _RovingScope.maybeOf(context);
    if (identical(scope, _scope)) return;
    _scope?.unregister(_node);
    _scope = scope;
    _scope?.register(_node);
    _node.skipTraversal = scope != null;
  }

  @override
  void dispose() {
    _scope?.unregister(_node);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _node);
}
