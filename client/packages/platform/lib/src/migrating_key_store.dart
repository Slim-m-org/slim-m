// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [KeyStore] that adopts secrets an earlier build kept under a stricter
/// keychain class, one handle at a time, the first time each is touched.
library;

import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'key_store.dart';

/// Reads and writes [primary]; a secret still in [legacy] is moved over first.
///
/// The keychain keeps one item per account whatever its accessibility, so the
/// new copy cannot be added beside the old one: the old item is deleted (a
/// delete ignores accessibility) and then the new one written. A failed write
/// puts the old copy back, so a move never costs the secret.
///
/// Every operation of every instance runs on one process-wide queue, because
/// two instances racing a move would delete each other's fresh copy.
class MigratingKeyStore implements KeyStore {
  MigratingKeyStore({required this.primary, required this.legacy});

  final KeyStore primary;
  final KeyStore legacy;

  static Future<void> _queue = Future<void>.value();

  final _settled = <KeyHandle>{};

  static Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// A legacy read that fails (a locked phone) propagates: that is a retry
  /// later, never a sign-out.
  Future<String?> _moveFromLegacy(KeyHandle handle) async {
    if (_settled.contains(handle)) return null;
    final value = await legacy.read(handle);
    if (value == null) {
      _settled.add(handle);
      return null;
    }
    try {
      await legacy.delete(handle);
      await primary.put(handle, value);
      _settled.add(handle);
    } catch (error, stack) {
      AppLog.swallowed(LogTag.auth, 'Could not move a saved secret; will retry',
          error, stack);
      await legacy.put(handle, value).then<void>((_) {}).catchError(
            (Object e, StackTrace s) => AppLog.swallowed(
                LogTag.auth, 'Could not restore a saved secret', e, s),
          );
    }
    return value;
  }

  @override
  Future<KeyHandle> put(String name, String secret) => _serialized(() async {
        await _moveFromLegacy(name);
        return primary.put(name, secret);
      });

  @override
  Future<String?> read(KeyHandle handle) => _serialized(() async {
        final current = await primary.read(handle);
        if (current != null) {
          _settled.add(handle);
          return current;
        }
        return _moveFromLegacy(handle);
      });

  @override
  Future<void> delete(KeyHandle handle) => _serialized(() async {
        await primary.delete(handle);
        await _deleteLegacy(() => legacy.delete(handle));
      });

  @override
  Future<void> clear() => _serialized(() async {
        await primary.clear();
        await _deleteLegacy(legacy.clear);
      });

  Future<void> _deleteLegacy(Future<void> Function() action) =>
      action().catchError((Object error, StackTrace stack) {
        AppLog.swallowed(
            LogTag.auth, 'Could not clear an old saved secret', error, stack);
      });

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) =>
      primary.sign(handle, payload);
}
