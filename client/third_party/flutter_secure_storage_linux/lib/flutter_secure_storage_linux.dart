// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Registers no backend: the Linux client never constructs `SecureKeyStore`.
library;

/// The Dart-side registration hook Flutter calls at startup; it has nothing to register.
class FlutterSecureStorageLinuxStub {
  static void registerWith() {}
}
