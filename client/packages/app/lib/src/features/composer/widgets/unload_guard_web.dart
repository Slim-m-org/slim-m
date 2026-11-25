// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser half of `unload_guard.dart`.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

final _owners = <Object>{};
JSFunction? _listener;

/// Marks [owner] as holding work a tab close would lose, or as done.
void guardUnload(Object owner, {required bool active}) {
  if (active) {
    _owners.add(owner);
  } else {
    _owners.remove(owner);
  }
  if (_owners.isEmpty) return _remove();
  _listener ??= _confirm.toJS;
  web.window.addEventListener('beforeunload', _listener);
}

void _remove() {
  final listener = _listener;
  if (listener != null) {
    web.window.removeEventListener('beforeunload', listener);
  }
  _listener = null;
}

void _confirm(web.BeforeUnloadEvent event) => event.preventDefault();
