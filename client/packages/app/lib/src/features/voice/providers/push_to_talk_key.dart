// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The key held to talk in this window, for key handlers that cannot read a provider.
library;

import 'package:flutter/services.dart';

/// Published by the mounted `PushToTalkListener`, null while push-to-talk is off.
abstract final class PushToTalkKey {
  static Object? _owner;
  static LogicalKeyboardKey? _key;

  static LogicalKeyboardKey? get inWindow => _key;

  static void publish(Object owner, LogicalKeyboardKey? key) {
    _owner = owner;
    _key = key;
  }

  /// An account switch mounts the next listener before the last one goes, so only the publisher may clear it.
  static void withdraw(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _key = null;
  }
}
