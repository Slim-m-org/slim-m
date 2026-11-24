// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// This device's push-encryption keypair.
///
/// The server seals a push envelope to the device's public key; the private
/// key never leaves the device. On iOS the Notification Service Extension
/// opens that envelope in its own process, reading this same key out of the
/// shared keychain group; everywhere else nothing opens one yet.
///
/// The job here either way is generating the pair once and making it survive
/// restarts: a device that registered a new key on every launch would orphan
/// every envelope already sealed to the one before it.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'key_store.dart';

/// The handle the private key is stored under. Exposed so tests and callers
/// sharing a [KeyStore] with other secrets do not need to guess it.
const devicePushKeyHandle = 'push_x25519_private_key';

/// Generates, persists, and reuses this device's X25519 keypair.
class DevicePushKeys {
  DevicePushKeys(
    this._keyStore, {
    KeyStore? legacy,
    String handle = devicePushKeyHandle,
  })  : _legacy = legacy,
        _handle = handle;

  final KeyStore _keyStore;

  /// A store an earlier build of this app kept the key in, moved out of on
  /// first read; null when nothing ever moved, which is every platform where
  /// `pushKeyHasItsOwnStore` is false.
  final KeyStore? _legacy;

  final String _handle;
  static final _algorithm = X25519();

  /// This device's public key, base64-encoded the way `PUT /push` expects it.
  /// Generates and persists a keypair the first time this is called; every
  /// later call, including after a restart, reuses the stored one.
  Future<String> publicKeyBase64() {
    final inFlight = _inFlight[_handle];
    if (inFlight != null) return inFlight;
    final created = _publicKeyBase64().whenComplete(() {
      _inFlight.remove(_handle);
    });
    return _inFlight[_handle] = created;
  }

  /// One load-or-create per handle in this process: every signed-in account
  /// has its own container and so its own instance, over one device-wide key.
  static final _inFlight = <String, Future<String>>{};

  Future<String> _publicKeyBase64() async {
    final keyPair = await _loadOrCreate();
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  Future<SimpleKeyPair> _loadOrCreate() async {
    final stored = await _keyStore.read(_handle);
    if (stored != null) {
      return _algorithm.newKeyPairFromSeed(base64Decode(stored));
    }

    final moved = await _moveFromLegacy();
    if (moved != null) {
      return _algorithm.newKeyPairFromSeed(base64Decode(moved));
    }

    final keyPair = await _algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await _keyStore.put(_handle, base64Encode(seed));
    return keyPair;
  }

  /// Moves a key an earlier build wrote elsewhere, returning it, or null when
  /// there is nothing to move.
  ///
  /// Generating a fresh key instead would be recoverable - the next
  /// `PUT /push` re-registers it - but only for envelopes sealed after that
  /// registration lands, and every one already in flight to this device would
  /// be undecryptable. A one-time read costs a keychain lookup on the first
  /// launch after upgrade and nothing after that.
  ///
  /// The old copy is deleted rather than left behind: a private key sitting
  /// in a second, less protected slot forever is worse than a downgrade
  /// having to re-register. That delete is safe only because the two stores
  /// differ in the attributes their queries carry, so it cannot match the
  /// copy just written - the two must never be configured identically.
  Future<String?> _moveFromLegacy() async {
    final legacy = _legacy;
    if (legacy == null) return null;

    final stored = await legacy.read(_handle);
    if (stored == null) return null;

    await _keyStore.put(_handle, stored);
    await legacy.delete(_handle);
    return stored;
  }
}
