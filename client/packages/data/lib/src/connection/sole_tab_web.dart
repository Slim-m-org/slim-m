// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:js_interop';

import 'sole_tab_claim.dart';

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

class _BrowserLocks implements TabLockManager {
  _BrowserLocks(this._manager);
  final _LockManager _manager;

  @override
  void requestIfAvailable(
    String name,
    void Function(bool granted) onResult,
    void Function(Object error) onError,
  ) {
    JSAny? hold(JSAny? lock) {
      onResult(lock != null);
      return lock == null ? null : Completer<void>().future.toJS;
    }

    try {
      _manager
          .request(
            name,
            _LockOptions(ifAvailable: true, mode: 'exclusive'),
            hold.toJS,
          )
          .toDart
          .catchError((Object error) {
        onError(error);
        return null;
      });
    } on Object catch (error) {
      onError(error);
    }
  }
}

/// Takes a Web Lock on [database] that lasts until this tab closes; false
/// when another tab holds it, or this tab claimed it before.
Future<bool> claimSoleTab(String database) {
  final manager = _locks;
  return claimSoleTabWith(
    manager == null ? null : _BrowserLocks(manager),
    database,
  );
}
