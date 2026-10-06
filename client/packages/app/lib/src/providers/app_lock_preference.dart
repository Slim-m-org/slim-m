// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether opening slim-m needs Face ID, a fingerprint, or the device
/// passcode first. Off by default, matching `HighContrastController`'s own
/// reasoning in `display_preferences.dart`: this changes something
/// meaningful about how the app behaves, so nothing changes for an install
/// that has never opened the control.
///
/// This is the one place that also drives the native privacy shield
/// ([AppLockWindowChannel]): every write here, plus [restore] once at
/// bootstrap, tells the platform side too, so `FLAG_SECURE`/the iOS
/// task-switcher cover always agrees with what this preference says, without
/// a caller ever having to remember to call both.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import 'preference_controller.dart';
import 'providers.dart';

const appLockPreferenceKey = 'slimm.security.app_lock';

/// The native bridge for the privacy shield. A provider, like
/// `apnsTokenChannelProvider`, so a test can substitute one that records
/// calls instead of touching a real platform channel.
final appLockWindowChannelProvider = Provider<AppLockWindowChannel>(
  (ref) => AppLockWindowChannel(),
);

class AppLockPreferenceController extends StateNotifier<bool>
    implements RestorablePreference {
  AppLockPreferenceController(this._ref) : super(false);

  final Ref _ref;

  @override
  Future<void> restore() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      state = prefs.getBool(appLockPreferenceKey) ?? false;
    } catch (_) {
      // Off is always a safe default; see HighContrastController's own restore.
    }
    await _ref.read(appLockWindowChannelProvider).setPrivacyShield(state);
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    await _ref.read(appLockWindowChannelProvider).setPrivacyShield(enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(appLockPreferenceKey, enabled);
  }
}

final appLockPreferenceProvider =
    StateNotifierProvider<AppLockPreferenceController, bool>(
      AppLockPreferenceController.new,
    );
