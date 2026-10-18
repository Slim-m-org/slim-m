// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Startup for a host-managed install: the fresh-install wipe, then each
/// account's stored session into its own container.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart';

import '../../../providers/providers.dart';
import 'account_host.dart';
import 'account_store.dart';

/// Clears a keychain left over from a deleted install, the way [restoreSession]
/// does, and reports whether this launch is that first one.
///
/// Guarded like [restoreSession]: a broken store must reach sign-in, not crash launch.
Future<bool> wipeKeychainOnFreshInstall(ProviderContainer container) async {
  final keyStore = container.read(keyStoreProvider);
  try {
    await migrateLegacyFileSecretsIfNeeded();
    final prefs = await container.read(preferencesProvider.future);
    if (prefs.getBool(hasLaunchedBeforeKey) == true) return false;
    await keyStore.clear();
    final pushKeys = container.read(pushKeyStoreProvider);
    if (!identical(pushKeys, keyStore)) await pushKeys.clear();
    await prefs.setBool(hasLaunchedBeforeKey, true);
    container.read(isFreshInstallProvider.notifier).state = true;
    return true;
  } catch (_) {
    return false;
  }
}

/// Restores [runtime]'s server and session. Never deletes what it cannot read:
/// a failure leaves the account signed out this run and flags a retry on activation.
Future<bool> restoreAccountSession(
  AccountStore store,
  AccountRuntime runtime,
) async {
  final account = runtime.account;
  if (account == null) return false;
  final container = runtime.container;
  container.read(chosenServerProvider.notifier).restore(account.serverUrl);
  try {
    final stored = await store.readSession(account);
    runtime.slot.restoreFailed = false;
    if (stored == null) return false;
    final tokens = TokenPair.fromJson(
      jsonDecode(stored) as Map<String, dynamic>,
    );
    container.read(sessionProvider).set(tokens);
    return true;
  } catch (_) {
    runtime.slot.restoreFailed = true;
    return false;
  }
}
