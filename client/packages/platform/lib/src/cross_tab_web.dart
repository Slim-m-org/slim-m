// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'cross_tab.dart';

CrossTab createCrossTab() => _BrowserTabs();

class _BrowserTabs implements CrossTab {
  @override
  Future<T> exclusive<T>(String name, Future<T> Function() body) {
    final locks = _locks;
    // A browser without Web Locks keeps the old per-tab behaviour.
    if (locks == null) return body();
    final result = Completer<T>();
    final granted = ((JSAny? _) {
      final run = Future<T>.sync(body);
      run.then(result.complete, onError: result.completeError);
      return run.then<JSAny?>((_) => null, onError: (_) => null).toJS;
    }).toJS;
    unawaited(
      locks.request(name, granted).toDart.then<void>((_) {},
          onError: (Object e) {
        if (!result.isCompleted) result.completeError(e);
      }),
    );
    return result.future;
  }

  web.LockManager? get _locks {
    try {
      return web.window.navigator.locks;
    } on Object {
      return null;
    }
  }

  @override
  Stream<void> get storageChanges =>
      web.EventStreamProviders.storageEvent.forTarget(web.window);
}
