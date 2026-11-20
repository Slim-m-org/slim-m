// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Asks before a settings draft behind a Save bar is left, so closing never
/// drops an unsaved edit without a word.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/close_screen.dart';
import '../../../widgets/confirm_dialog.dart';
import 'settings_sub_pages.dart';

/// Whether a draft holds unsaved edits, and the question asked before it is lost.
class DraftLeaveGuard extends ChangeNotifier implements SettingsLeaveGuard {
  DraftLeaveGuard(this._confirm);

  final Future<bool> Function() _confirm;
  bool _dirty = false;
  bool _disposed = false;

  @override
  bool get blocking => _dirty;

  set dirty(bool value) {
    if (_disposed || value == _dirty) return;
    _dirty = value;
    notifyListeners();
  }

  @override
  Future<bool> confirmLeave() => _confirm();

  /// True when nothing is unsaved, or the person chose to discard it.
  Future<bool> allowLeave() async => !_dirty || await _confirm();

  /// Sets [dirty] from [isDirty] once this frame is built, since a build may not notify its ancestors.
  void reportAfterFrame(bool Function() isDirty) {
    if (_disposed || isDirty() == _dirty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => dirty = isDirty());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The question every settings draft asks before its edits are thrown away.
Future<bool> confirmDiscardChanges(BuildContext context, {Key? confirmKey}) =>
    confirmChoice(
      context,
      title: 'Discard your changes?',
      message: 'What you changed since the last save is lost.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep editing',
      confirmVariant: AppButtonVariant.danger,
      confirmKey: confirmKey,
    );

/// True when the drafts this [context] sits beside let go: the pane's in a
/// settings pane, otherwise every one on its route, asking each that is dirty.
Future<bool> draftsLetGo(BuildContext context) =>
    SettingsSubPages.maybeOf(context)?.canLeave() ?? routeLetsGo(context);

/// Guards a draft behind a Save bar: in a settings pane it is the pane's guard,
/// anywhere else a back or dismiss asks first while [dirty].
class DraftLeaveScope extends StatefulWidget {
  const DraftLeaveScope({super.key, required this.dirty, required this.child});

  final bool dirty;
  final Widget child;

  @override
  State<DraftLeaveScope> createState() => _DraftLeaveScopeState();
}

class _DraftLeaveScopeState extends State<DraftLeaveScope> {
  late final _draft = DraftLeaveGuard(() => confirmDiscardChanges(context));
  late final SettingsSubPageStack? _pane = SettingsSubPages.maybeOf(context);
  Route<Object?>? _route;

  @override
  void initState() {
    super.initState();
    _pane?.setPaneGuard(_draft);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pane != null) return;
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _releaseRoute();
    _route = route;
    if (route != null) addRouteLeaveCheck(route, _draft.allowLeave);
  }

  void _releaseRoute() {
    final route = _route;
    if (route != null) removeRouteLeaveCheck(route, _draft.allowLeave);
    _route = null;
  }

  @override
  void dispose() {
    _releaseRoute();
    _pane?.releasePaneGuard(_draft);
    _draft.dispose();
    super.dispose();
  }

  Future<void> _popUnlessKept(bool didPop) async {
    if (didPop || !await _draft.allowLeave() || !mounted) return;
    _draft.dirty = false;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    _draft.reportAfterFrame(() => widget.dirty);
    if (_pane != null) return widget.child;
    return ListenableBuilder(
      listenable: _draft,
      builder: (context, child) => PopScope(
        canPop: !_draft.blocking,
        onPopInvokedWithResult: (didPop, _) =>
            unawaited(_popUnlessKept(didPop)),
        child: child!,
      ),
      child: widget.child,
    );
  }
}
