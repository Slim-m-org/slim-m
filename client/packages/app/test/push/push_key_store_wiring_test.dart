// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which store the push private key is read and written through.
///
/// iOS keeps it in its own keychain group so the Notification Service
/// Extension can read that one key, and only that one key, from a separate
/// process. Every other platform has no second process and no keychain
/// groups, and must therefore keep using the store it already had - the very
/// same instance, not an equivalent one, because `FileKeyStore` serialises
/// writes per instance and two of them over one file would put a session
/// write and a push-key write back into the read-modify-write race that queue
/// exists to prevent.
///
/// These run on a Linux host, so they describe the non-iOS half directly. The
/// iOS half is asserted on the platform package's own side, against the
/// keychain options `SecureKeyStore.forPushKey` configures.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

void main() {
  test('off iOS the push key uses the one store, not a second one over the '
      'same file', () {
    expect(pushKeyHasItsOwnStore, isFalse, reason: 'this host is not iOS');

    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      identical(
        container.read(pushKeyStoreProvider),
        container.read(keyStoreProvider),
      ),
      isTrue,
    );
  });

  test('off iOS there is no earlier location to move a key out of', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(legacyPushKeyStoreProvider), isNull);
  });

  /// A test that overrides the one store has to keep describing the whole
  /// picture, or every existing push test would quietly start reading a real
  /// platform store instead of the fake one it was handed.
  test('overriding the store reaches the push key too', () {
    final fake = InMemoryKeyStore();
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    expect(identical(container.read(pushKeyStoreProvider), fake), isTrue);
  });
}
