// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The key the local database is encrypted with, and what can go wrong with it.
///
/// Kept free of `dart:io` so the conditional export in `connection.dart` can
/// hand the same signature to every backend, including the browser one that
/// never uses a key.
library;

import 'dart:math';

/// Where the database key is kept. The app backs this with the platform
/// key store; tests supply a fake so no real keychain entry is ever touched.
abstract interface class DatabaseKeyStore {
  /// The stored key as 64 hex characters, or null when none was ever stored.
  /// Throws when the store itself cannot be reached: null means "definitely
  /// absent", and callers act on that difference.
  Future<String?> read();

  /// Stores or replaces the key.
  Future<void> write(String key);
}

/// Why the local cache was cleared and refetched instead of opened.
enum DatabaseResetReason {
  /// An encrypted database exists but its key is gone, as after a keychain
  /// wipe or a restore that brought the file back without the key.
  keyMissing,

  /// The key is present but the file does not open with it, which also
  /// covers a file too damaged to read.
  unreadable,
}

/// The key store could not be reached, so the database was left untouched.
///
/// Distinct from a reset on purpose: a keychain that errors once may work on
/// the next attempt, and clearing the cache or minting a new key now would
/// strand the data it holds for good.
class LocalDatabaseKeyUnavailable implements Exception {
  const LocalDatabaseKeyUnavailable(this.cause);

  final Object cause;

  @override
  String toString() => 'LocalDatabaseKeyUnavailable: $cause';
}

/// The linked SQLite has no cipher, so a key would be silently ignored and the
/// file written in the clear. Nothing is opened or written when this is thrown.
class DatabaseEncryptionUnavailable implements Exception {
  const DatabaseEncryptionUnavailable(this.detail);

  final String detail;

  @override
  String toString() => 'DatabaseEncryptionUnavailable: $detail';
}

/// A live process, most likely another copy of the app, holds the database
/// file, so it was left alone.
class DatabaseInUseElsewhere implements Exception {
  const DatabaseInUseElsewhere(this.detail);

  final String detail;

  @override
  String toString() => 'DatabaseInUseElsewhere: $detail';
}

/// The database neither opened nor could be replaced; [detail] is the cause.
class DatabaseUnopenable implements Exception {
  const DatabaseUnopenable(this.detail);

  final String detail;

  @override
  String toString() => 'DatabaseUnopenable: $detail';
}

/// A SQLite failure from a statement that carried the key, stripped of the
/// statement text `SqliteException.toString` would otherwise print into logs.
class DatabaseCipherException implements Exception {
  const DatabaseCipherException(this.resultCode, this.message);

  final int resultCode;
  final String message;

  @override
  String toString() => 'DatabaseCipherException($resultCode): $message';
}

/// A fresh 256-bit key from the operating system's CSPRNG, as hex.
String generateDatabaseKey([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => source.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
