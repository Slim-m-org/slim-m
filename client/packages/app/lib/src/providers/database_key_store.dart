// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bridges the platform [KeyStore] to the key the local database is sealed
/// with, and tells the user when that key was lost.
/// See docs/decisions/0042-encrypt-local-database.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../widgets/banner_above_child.dart';

/// The handle the database key is stored under in [KeyStore].
const databaseKeyHandle = 'slimm.database.key';

/// The database key, kept in the same store as the session token.
class KeyStoreDatabaseKey implements DatabaseKeyStore {
  KeyStoreDatabaseKey(this._store);

  final KeyStore _store;

  @override
  Future<String?> read() => _store.read(databaseKeyHandle);

  @override
  Future<void> write(String key) async {
    await _store.put(databaseKeyHandle, key);
  }
}

/// Set when the local cache was cleared because its key was lost; the shell
/// says so until the user dismisses it.
final databaseResetProvider = StateProvider<DatabaseResetReason?>(
  (ref) => null,
);

/// What the shell shows when the store cannot open, in place of a raw
/// exception.
String localStoreErrorMessage(Object error) => switch (error) {
  LocalDatabaseKeyUnavailable() =>
    "This device's secure storage could not be reached, so the saved copy "
        'of your messages stays locked. Nothing was deleted. Try again, and '
        'if it keeps failing, unlock or restart your keychain.',
  DatabaseEncryptionUnavailable() =>
    'This build cannot encrypt the saved copy of your messages, so it will '
        'not store them. Nothing was written or deleted.',
  _ => 'Could not load this screen.',
};

/// Says that the local cache was cleared and is downloading again.
///
/// Informational, so an [AppCallout] rather than an error state; the
/// SafeArea and stripped padding follow `NewDeviceBannerHost`.
class DatabaseResetNotice extends ConsumerWidget {
  const DatabaseResetNotice({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reason = ref.watch(databaseResetProvider);
    return BannerAboveChild(
      banner: reason == null ? null : _ResetBanner(reason: reason),
      child: child,
    );
  }
}

class _ResetBanner extends ConsumerWidget {
  const _ResetBanner({required this.reason});

  final DatabaseResetReason reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: AppCallout(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_resetMessage(reason)),
                AppButton(
                  label: 'Dismiss',
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.sm,
                  onPressed: () =>
                      ref.read(databaseResetProvider.notifier).state = null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _resetMessage(DatabaseResetReason reason) =>
    reason == DatabaseResetReason.keyMissing
    ? 'This device lost the key to its saved messages, so they were cleared '
          'and are downloading again from the server.'
    : "This device's saved messages could not be read, so they were cleared "
          'and are downloading again from the server.';
