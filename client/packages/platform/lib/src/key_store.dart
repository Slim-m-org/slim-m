// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where secrets live.
///
/// The interface is deliberately narrower than "a map of strings": it never
/// hands back a key as bytes you can copy, only asks the store to *use* one.
/// That shape is what lets a later move to hardware-backed, non-extractable
/// keys (Secure Enclave, StrongBox, a TPM) happen without touching a single
/// call site, because callers never had the raw material to begin with.
///
/// Today the only secrets are session tokens, which are opaque strings the
/// server issues. When E2EE arrives the same interface carries signing and
/// agreement keys, and the in-memory test implementation is the one that gets
/// replaced, not the callers.
library;

import 'dart:async';

/// A handle to a stored secret. Holding one does not mean holding the secret.
typedef KeyHandle = String;

/// Storage for secrets that must not end up in plain preferences or logs.
abstract interface class KeyStore {
  /// Stores or replaces a secret, returning its handle.
  Future<KeyHandle> put(String name, String secret);

  /// Reads a secret back. Present because session tokens genuinely must be sent
  /// over the wire; key material added later should use [sign] instead and
  /// never round-trip through here.
  Future<String?> read(KeyHandle handle);

  /// Deletes a secret. Called on sign-out and account deletion.
  Future<void> delete(KeyHandle handle);

  /// Removes everything this app stored, for sign-out on a shared machine.
  Future<void> clear();

  /// Signs with the named key without revealing it. Unimplemented until E2EE
  /// exists, but present so the seam is real rather than promised: a hardware
  /// backend implements this and never implements [read] for key material.
  Future<List<int>> sign(KeyHandle handle, List<int> payload);
}
