// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linux secret storage: the Secret Service keyring when one answers, the
/// owner-only file when none does.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'key_store.dart';
import 'persistent_key_store.dart';

/// Thrown when the keyring held this install's secrets once and does not answer now.
///
/// Callers treat a failed read as "retry later", never as signed out.
class KeyringUnavailableException implements Exception {
  const KeyringUnavailableException();

  @override
  String toString() => 'The system keyring did not answer';
}

/// Picks its backend once per process, on first use, by asking the Secret
/// Service to store, read and delete a probe entry.
///
/// A session with no keyring agent (a bare window manager, a container) must
/// still keep a sign-in, so the file stays the fallback. When the keyring
/// answers, what the file holds moves over and the file is removed; if that
/// move cannot finish, the file stays the store for this run and the next
/// launch tries again. Once the keyring has taken over it is the only store:
/// a locked keyring then fails the call and is asked again, never replaced by
/// an empty file.
class LinuxKeyStore implements KeyStore {
  LinuxKeyStore({
    FileKeyStore? file,
    KeyStore? secretService,
    this.probeTimeout = const Duration(seconds: 10),
  })  : _file = file ?? FileKeyStore(),
        _secretService = secretService;

  @visibleForTesting
  static const probeHandle = 'slimm.secret-service.probe';

  final Duration probeTimeout;
  final FileKeyStore _file;
  final KeyStore? _secretService;
  Future<KeyStore>? _backend;

  Future<KeyStore> _resolve() => _backend ??= _choose().catchError(
        (Object error, StackTrace stack) {
          _backend = null;
          Error.throwWithStackTrace(error, stack);
        },
      );

  Future<KeyStore> _choose() async {
    final keyring = _secretService ?? SecureKeyStore();
    final authoritative = await _keyringIsAuthoritative();
    if (!await _answers(keyring)) {
      if (authoritative) throw const KeyringUnavailableException();
      return _file;
    }
    final moved = await migrateLegacyFileSecrets(
      legacy: _file,
      destination: keyring,
    );
    if (!moved) return _file;
    await _markAuthoritative();
    return keyring;
  }

  Future<bool> _keyringIsAuthoritative() async {
    try {
      return await _file.keyringIsAuthoritative();
    } catch (error, stack) {
      AppLog.swallowed(
          LogTag.auth, 'Could not read the keyring marker', error, stack);
      return false;
    }
  }

  Future<void> _markAuthoritative() async {
    try {
      await _file.markKeyringAuthoritative();
    } catch (error, stack) {
      AppLog.swallowed(LogTag.auth, 'Could not record the keyring as the store',
          error, stack);
    }
  }

  Future<bool> _answers(KeyStore keyring) async {
    try {
      return await _withDeadline(_roundTrip(keyring));
    } catch (error, stack) {
      AppLog.swallowed(LogTag.auth, 'No Secret Service answered', error, stack);
      return false;
    }
  }

  /// Waits on the wall clock: a native call that never returns must not be
  /// able to stall on, or be held open by, a fake clock.
  Future<bool> _withDeadline(Future<bool> attempt) {
    final result = Completer<bool>();
    final deadline = Zone.root.createTimer(probeTimeout, () {
      if (!result.isCompleted) result.complete(false);
    });
    attempt.then<void>(
      (answered) {
        deadline.cancel();
        if (!result.isCompleted) result.complete(answered);
      },
      onError: (Object error, StackTrace stack) {
        deadline.cancel();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  Future<bool> _roundTrip(KeyStore keyring) async {
    final handle = '$probeHandle.${identityHashCode(this)}';
    await keyring.put(handle, 'probe');
    final back = await keyring.read(handle);
    await keyring.delete(handle);
    return back == 'probe';
  }

  @override
  Future<KeyHandle> put(String name, String secret) async =>
      (await _resolve()).put(name, secret);

  @override
  Future<String?> read(KeyHandle handle) async =>
      (await _resolve()).read(handle);

  @override
  Future<void> delete(KeyHandle handle) async =>
      (await _resolve()).delete(handle);

  @override
  Future<void> clear() async => (await _resolve()).clear();

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) =>
      throw UnsupportedError(
        'signing needs a real key backend; wire one before shipping E2EE',
      );
}
