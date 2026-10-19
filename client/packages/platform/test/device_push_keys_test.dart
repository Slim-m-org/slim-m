// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the device push keypair: generated once, reused after, and
/// never shared between devices.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

void main() {
  group('DevicePushKeys', () {
    test('the public key is base64 of 32 raw bytes', () async {
      final publicKey =
          await DevicePushKeys(InMemoryKeyStore()).publicKeyBase64();
      expect(base64Decode(publicKey), hasLength(32));
    });

    test('a keypair is generated once and reused, not regenerated', () async {
      final store = InMemoryKeyStore();
      final first = await DevicePushKeys(store).publicKeyBase64();

      // A fresh DevicePushKeys over the same store stands in for a later
      // launch: a changed answer means the private key was never persisted.
      final second = await DevicePushKeys(store).publicKeyBase64();

      expect(second, first);
    });

    test('two devices never end up with the same key', () async {
      final a = await DevicePushKeys(InMemoryKeyStore()).publicKeyBase64();
      final b = await DevicePushKeys(InMemoryKeyStore()).publicKeyBase64();
      expect(a, isNot(b));
    });
  });

  /// iOS moved this key into its own keychain group, with an accessibility
  /// that lets a locked phone read it. A keychain query is a search over
  /// attributes, so an item written under the old ones is invisible to a read
  /// under the new: without the move, an existing install silently generates a
  /// second keypair and every envelope already sealed to the first becomes
  /// undecryptable.
  group('DevicePushKeys, moving a key an earlier build wrote', () {
    test('the moved key is the same key, not a fresh one', () async {
      final legacy = InMemoryKeyStore();
      final before = await DevicePushKeys(legacy).publicKeyBase64();

      final after = await DevicePushKeys(
        InMemoryKeyStore(),
        legacy: legacy,
      ).publicKeyBase64();

      expect(after, before);
    });

    test('the old copy is deleted rather than left behind', () async {
      final legacy = InMemoryKeyStore();
      await DevicePushKeys(legacy).publicKeyBase64();
      expect(await legacy.read(devicePushKeyHandle), isNotNull);

      await DevicePushKeys(InMemoryKeyStore(), legacy: legacy)
          .publicKeyBase64();

      expect(await legacy.read(devicePushKeyHandle), isNull);
    });

    test('the moved key lands in the new store, so a later launch reuses it',
        () async {
      final legacy = InMemoryKeyStore();
      final moved = InMemoryKeyStore();
      final before = await DevicePushKeys(legacy).publicKeyBase64();

      await DevicePushKeys(moved, legacy: legacy).publicKeyBase64();
      // No legacy this time: the key has to have landed, or this regenerates.
      final later = await DevicePushKeys(moved).publicKeyBase64();

      expect(later, before);
    });

    test('a legacy store with nothing in it just generates a fresh key',
        () async {
      final key = await DevicePushKeys(
        InMemoryKeyStore(),
        legacy: InMemoryKeyStore(),
      ).publicKeyBase64();

      expect(base64Decode(key), hasLength(32));
    });

    /// The order matters and the wrong one is silently destructive: a build
    /// that read the legacy store first would overwrite an already-migrated
    /// key with a stale copy every launch until the legacy one was cleared.
    test(
        'a key already in the new store wins, and the legacy copy is left '
        'alone rather than overwriting it', () async {
      final legacy = InMemoryKeyStore();
      final current = InMemoryKeyStore();
      await DevicePushKeys(legacy).publicKeyBase64();
      final wanted = await DevicePushKeys(current).publicKeyBase64();

      final answered =
          await DevicePushKeys(current, legacy: legacy).publicKeyBase64();

      expect(answered, wanted);
      expect(await legacy.read(devicePushKeyHandle), isNotNull);
    });

    /// Every platform but iOS passes null here, because nothing ever moved
    /// there; that must behave exactly as it did before this existed.
    test('no legacy store at all is the ordinary generate-and-persist path',
        () async {
      final store = InMemoryKeyStore();
      final first = await DevicePushKeys(store).publicKeyBase64();
      final second =
          await DevicePushKeys(store, legacy: null).publicKeyBase64();

      expect(second, first);
    });
  });
}
