// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two device preferences kept apart from message chimes: the soft interface
/// cues (send, receive in view, call join, leave, mute, deafen, ringback) and
/// haptics, so turning sounds off no longer silences touch feedback.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart' show AppHaptics;

import '../../../providers/providers.dart';

const uiSoundsEnabledKey = 'slimm.notifications.ui_sounds_enabled';
const hapticsEnabledKey = 'slimm.notifications.haptics_enabled';

class _BoolPreference extends StateNotifier<bool> {
  _BoolPreference(this._ref, this._key) : super(true) {
    _load();
  }

  final Ref _ref;
  final String _key;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    if (!mounted) return;
    state = prefs.getBool(_key) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_key, enabled);
  }
}

class UiSoundSettingsController extends _BoolPreference {
  UiSoundSettingsController(Ref ref) : super(ref, uiSoundsEnabledKey);
}

/// Mirrors its state into [AppHaptics.enabled], which every haptic call reads.
class HapticsSettingsController extends _BoolPreference {
  HapticsSettingsController(Ref ref) : super(ref, hapticsEnabledKey) {
    addListener((enabled) => AppHaptics.enabled = enabled);
  }
}

final uiSoundSettingsProvider =
    StateNotifierProvider<UiSoundSettingsController, bool>(
      UiSoundSettingsController.new,
    );

final hapticsSettingsProvider =
    StateNotifierProvider<HapticsSettingsController, bool>(
      HapticsSettingsController.new,
    );

/// Bumped by the composer after a message was posted, so the sound controller
/// can cue it without the composer owning an audio player.
final messageSentSignalProvider = StateProvider<int>((ref) => 0);
