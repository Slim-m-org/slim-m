// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:slimm_platform/platform.dart' show isLinuxHost, isWindowsHost;

import 'atomic_preferences_store.dart';

/// Swaps in [AtomicPreferencesStore] on Linux and Windows, before the first
/// `SharedPreferences.getInstance`; every other platform keeps its own store.
void registerPreferencesStore() {
  if (!isLinuxHost && !isWindowsHost) return;
  SharedPreferencesStorePlatform.instance = AtomicPreferencesStore();
}
