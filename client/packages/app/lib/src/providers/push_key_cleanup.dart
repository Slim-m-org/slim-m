// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Clearing the device's push key from every store a build may have written to.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart';

import 'providers.dart';

/// Deletes the push key from the current store and the legacy one.
///
/// On iOS a device that has not registered since upgrading still has the old
/// copy where an earlier build left it (see [legacyPushKeyStoreProvider]), and
/// clearing only the new location would leave the outgoing account's key for
/// the next account to inherit. Never throws: sign-out must not stop here.
Future<void> deleteDevicePushKeys(Ref ref) async {
  final legacy = ref.read(legacyPushKeyStoreProvider);
  for (final store in [
    ref.read(pushKeyStoreProvider),
    if (legacy != null) legacy,
  ]) {
    try {
      await store.delete(devicePushKeyHandle);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.push,
        'Could not delete the saved push key',
        error,
        stack,
      );
      // Keep going: the other store still needs clearing.
    }
  }
}
