// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linux secret storage: the Secret Service keyring when one answers, the
/// owner-only file when none does.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'key_store.dart';
import 'persistent_key_store.dart';

/// Picks its backend once per process, on first use, by asking the Secret
/// Service to store, read and delete a probe entry.
///
/// A session with no keyring agent (a bare window manager, a container) must
/// still keep a sign-in, so the file stays the fallback. When the keyring
/// answers, what the file holds moves over and the file is removed; if that
/// move cannot finish, the file stays the store for this run and the next
/// launch tries again.
class LinuxKeyStore implements KeyStore {
  LinuxKeyStore({
    FileKeyStore? file,
    KeyStore? secretService,
    this.probeTimeout = const Duration(seconds: 10),
  })  : _file = file ?? FileKeyStore(),
        _secretService = secretService;

  /// One instance for the process, so every caller shares one choice and one
  /// file queue.
  static final LinuxKeyStore shared = LinuxKeyStore();

  @visibleForTesting
  static const probeHandle = 'slimm.secret-service.probe';

  final Duration probeTimeout;
  final FileKeyStore _file;
  final KeyStore? _secretService;
  Future<KeyStore>? _backend;

  Future<KeyStore> _resolve() => _backend ??= _choose();

  Future<KeyStore> _choose() async {
    final keyring = _secretService ?? SecureKeyStore();
    if (!await _answers(keyring)) return _file;
    final moved = await migrateLegacyFileSecrets(
      legacy: _file,
      destination: keyring,
    );
    return moved ? keyring : _file;
  }

  Future<bool> _answers(KeyStore keyring) async {
    try {
      return await _roundTrip(keyring).timeout(probeTimeout);
    } catch (error, stack) {
      AppLog.swallowed(
          LogTag.auth,
          'No Secret Service answered; the owner-only file is used',
          error,
          stack);
      return false;
    }
  }

  Future<bool> _roundTrip(KeyStore keyring) async {
    await keyring.put(probeHandle, 'probe');
    final back = await keyring.read(probeHandle);
    await keyring.delete(probeHandle);
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
