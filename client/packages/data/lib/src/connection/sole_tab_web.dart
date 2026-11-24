// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:js_interop';

@JS('navigator.locks')
external _LockManager? get _locks;

extension type _LockManager._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
    String name,
    _LockOptions options,
    JSFunction callback,
  );
}

extension type _LockOptions._(JSObject _) implements JSObject {
  external factory _LockOptions({bool ifAvailable, String mode});
}

/// Takes a Web Lock that lasts until this tab closes; false when another tab
/// already holds it, or this tab claimed it before.
Future<bool> claimSoleTab() {
  final locks = _locks;
  if (locks == null) return Future.value(true);
  final granted = Completer<bool>();
  JSAny? hold(JSAny? lock) {
    granted.complete(lock != null);
    return lock == null ? null : Completer<void>().future.toJS;
  }

  locks.request(
    'slimm-sole-tab',
    _LockOptions(ifAvailable: true, mode: 'exclusive'),
    hold.toJS,
  );
  return granted.future;
}
