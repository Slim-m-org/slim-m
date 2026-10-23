// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import 'providers.dart';

/// Where secrets a background poll reads live: a first-unlock keychain store
/// on iOS, the ordinary store everywhere else.
final backgroundKeyStoreProvider = Provider<KeyStore>(
  (ref) => backgroundKeyHasItsOwnStore
      ? createBackgroundKeyStore()
      : ref.watch(keyStoreProvider),
);
