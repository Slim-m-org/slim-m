// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:web/web.dart' as web;

import 'background_image_store.dart';

BackgroundImageStore createBackgroundImageStore() =>
    IndexedDbBackgroundImageStore();

/// One record in an IndexedDB object store; localStorage is too small for a
/// picture.
class IndexedDbBackgroundImageStore implements BackgroundImageStore {
  static const _database = 'slimm-appearance';
  static const _store = 'background';
  static const _key = 'picture';

  Future<web.IDBDatabase> _open() {
    final done = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_database, 1);
    request.onupgradeneeded = ((web.Event _) {
      (request.result as web.IDBDatabase).createObjectStore(_store);
    }).toJS;
    request.onsuccess = ((web.Event _) {
      done.complete(request.result as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event _) {
      done.completeError(StateError('IndexedDB would not open'));
    }).toJS;
    return done.future;
  }

  Future<JSAny?> _run(
    String mode,
    web.IDBRequest Function(web.IDBObjectStore store) act,
  ) async {
    final db = await _open();
    try {
      final done = Completer<JSAny?>();
      final transaction = db.transaction(_store.toJS, mode);
      final request = act(transaction.objectStore(_store));
      // A write is only durable once its transaction commits, not when the request succeeds.
      transaction.oncomplete = ((web.Event _) {
        if (!done.isCompleted) done.complete(request.result);
      }).toJS;
      void fail(web.Event _) {
        if (!done.isCompleted) {
          done.completeError(StateError('IndexedDB transaction failed'));
        }
      }

      transaction.onerror = fail.toJS;
      transaction.onabort = fail.toJS;
      return await done.future;
    } finally {
      db.close();
    }
  }

  @override
  Future<Uint8List?> read() async {
    try {
      final stored = await _run('readonly', (s) => s.get(_key.toJS));
      return stored == null ? null : (stored as JSUint8Array).toDart;
    } catch (error, stack) {
      _log('read', error, stack);
      return null;
    }
  }

  @override
  Future<bool> write(Uint8List bytes) async {
    try {
      await _run('readwrite', (s) => s.put(bytes.toJS, _key.toJS));
      return true;
    } catch (error, stack) {
      _log('save', error, stack);
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _run('readwrite', (s) => s.delete(_key.toJS));
    } catch (error, stack) {
      _log('remove', error, stack);
    }
  }

  void _log(String what, Object error, StackTrace stack) => AppLog.swallowed(
    LogTag.media,
    'Could not $what the background picture',
    error,
    stack,
  );
}
