// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';
import 'dart:js_interop';
import 'dart:math';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:web/web.dart' as web;

import 'cross_tab.dart';

CrossTab createCrossTab() {
  _holdPresence();
  return _BrowserTabs();
}

const _presenceLock = 'slimm-tab-open';

/// Once per tab, however many accounts it hosts, so the held count is the tab count.
var _presenceHeld = false;

void _holdPresence() {
  final locks = _locks;
  if (_presenceHeld || locks == null) return;
  _presenceHeld = true;
  final forever = Completer<JSAny?>().future.toJS;
  final granted = ((JSAny? _) => forever).toJS;
  unawaited(
    locks
        .request(_presenceLock, web.LockOptions(mode: 'shared'), granted)
        .toDart
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) => AppLog.swallowed(
            LogTag.platform,
            'Could not mark this tab open',
            error,
            stack,
          ),
        ),
  );
}

web.LockManager? get _locks {
  try {
    return web.window.navigator.locks;
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Web Locks are unavailable in this browser context',
      error,
      stack,
    );
    return null;
  }
}

/// Session storage, unlike local storage, is one tab's own and outlives its reloads.
const _tabIdKey = 'slimm.tab_id';

/// Null when session storage is out of reach, so the server falls back to the
/// device's own tag, which a reload still matches.
String? _readOrMakeTabId() {
  try {
    final storage = web.window.sessionStorage;
    final held = storage.getItem(_tabIdKey);
    if (held != null && held.isNotEmpty) return held;
    final made = _randomTabId();
    storage.setItem(_tabIdKey, made);
    return made;
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Session storage is unavailable; voice tells this tab by its device',
      error,
      stack,
    );
    return null;
  }
}

String _randomTabId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class _BrowserTabs implements CrossTab {
  @override
  late final String? tabId = _readOrMakeTabId();

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

  @override
  Stream<void> get storageChanges =>
      web.EventStreamProviders.storageEvent.forTarget(web.window);

  @override
  Future<bool> anotherTabIsOpen() async {
    final locks = _locks;
    if (locks == null) return false;
    try {
      final snapshot = await locks.query().toDart;
      final open = snapshot.held.toDart.where((l) => l.name == _presenceLock);
      return open.length > 1;
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not count the open tabs',
        error,
        stack,
      );
      return false;
    }
  }
}
