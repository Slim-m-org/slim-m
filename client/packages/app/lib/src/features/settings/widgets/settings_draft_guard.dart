// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Asks before a settings draft behind a Save bar is left, so closing never
/// drops an unsaved edit without a word.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

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
Future<bool> confirmDiscardChanges(BuildContext context) => confirmChoice(
  context,
  title: 'Discard your changes?',
  message: 'What you changed since the last save is lost.',
  confirmLabel: 'Discard',
  cancelLabel: 'Keep editing',
  confirmVariant: AppButtonVariant.danger,
);
