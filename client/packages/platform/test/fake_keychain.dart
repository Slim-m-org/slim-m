// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A model of the iOS keychain rules the session store depends on: accessibility
/// is part of a lookup, a delete ignores it, one account holds one item, and a
/// WhenUnlocked item cannot be touched while the phone is locked.
library;

import 'package:slimm_platform/platform.dart';

enum Protection { whenUnlocked, afterFirstUnlock }

class FakeKeychain {
  final _items = <String, ({String value, Protection protection})>{};

  /// Whether the screen is locked right now.
  bool locked = false;

  /// Whether the phone has been unlocked at least once since boot.
  bool unlockedOnce = true;

  KeyStore view(Protection protection) => _KeychainView(this, protection);

  bool holds(String account) => _items.containsKey(account);

  Protection? protectionOf(String account) => _items[account]?.protection;

  bool _reachable(Protection protection) => switch (protection) {
        Protection.whenUnlocked => !locked,
        Protection.afterFirstUnlock => unlockedOnce,
      };
}

class _KeychainView implements KeyStore {
  _KeychainView(this._keychain, this._protection);

  final FakeKeychain _keychain;
  final Protection _protection;

  void _requireReachable() {
    if (!_keychain._reachable(_protection)) {
      throw StateError('errSecInteractionNotAllowed (-25308)');
    }
  }

  @override
  Future<KeyHandle> put(String name, String secret) async {
    _requireReachable();
    final existing = _keychain._items[name];
    if (existing != null && existing.protection != _protection) {
      throw StateError('errSecDuplicateItem (-25299)');
    }
    _keychain._items[name] = (value: secret, protection: _protection);
    return name;
  }

  @override
  Future<String?> read(KeyHandle handle) async {
    _requireReachable();
    final item = _keychain._items[handle];
    return item?.protection == _protection ? item!.value : null;
  }

  @override
  Future<void> delete(KeyHandle handle) async {
    _keychain._items.remove(handle);
  }

  @override
  Future<void> clear() async => _keychain._items.clear();

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) =>
      throw UnsupportedError('not modelled');
}
