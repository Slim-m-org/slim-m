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

/// What a lock callback returns to hold its lock until the tab goes.
final _forever = Completer<JSAny?>().future.toJS;

void _holdPresence() {
  final locks = _locks;
  if (_presenceHeld || locks == null) return;
  _presenceHeld = true;
  final granted = ((JSAny? _) => _forever).toJS;
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

/// The only shape the server takes, so a stored value in any other is never sent.
final _tabIdShape = RegExp(r'^[0-9a-f]{1,64}$');

/// Null when session storage is out of reach, so the server falls back to the
/// device's own tag, which a reload still matches.
Future<String?> _claimTabId() async {
  try {
    final storage = web.window.sessionStorage;
    final held = storage.getItem(_tabIdKey);
    // A duplicated tab copies session storage, so the id is ours only if no live tab holds it.
    if (held != null &&
        _tabIdShape.hasMatch(held) &&
        await _holdForTheTab(held)) {
      return held;
    }
    final made = _randomTabId();
    await _holdForTheTab(made);
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

/// Holds [id]'s lock for the life of this tab; false when another live tab
/// holds it. A reload's old document lets go of it before the new one asks.
Future<bool> _holdForTheTab(String id) {
  final locks = _locks;
  if (locks == null) return Future.value(true);
  final held = Completer<bool>();
  JSAny? granted(web.Lock? lock) {
    held.complete(lock != null);
    return lock == null ? null : _forever;
  }

  unawaited(
    locks
        .request(
          'slimm.tab.$id',
          web.LockOptions(ifAvailable: true),
          granted.toJS,
        )
        .toDart
        .then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        AppLog.swallowed(
          LogTag.platform,
          'Could not hold this tab id; keeping it unchecked',
          error,
          stack,
        );
        if (!held.isCompleted) held.complete(true);
      },
    ),
  );
  return held.future;
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
  late final Future<String?> tabId = _claimTabId();

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
