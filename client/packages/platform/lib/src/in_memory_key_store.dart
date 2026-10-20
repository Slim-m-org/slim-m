// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'key_store.dart';

/// A non-persistent [KeyStore] for tests: a secret that silently survived a
/// restart in plain memory would be worse than none.
class InMemoryKeyStore implements KeyStore {
  final Map<KeyHandle, String> _secrets = {};

  @override
  Future<KeyHandle> put(String name, String secret) async {
    _secrets[name] = secret;
    return name;
  }

  @override
  Future<String?> read(KeyHandle handle) async => _secrets[handle];

  @override
  Future<void> delete(KeyHandle handle) async {
    _secrets.remove(handle);
  }

  @override
  Future<void> clear() async => _secrets.clear();

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) {
    throw UnsupportedError(
      'signing needs a real key backend; wire one before shipping E2EE',
    );
  }
}
