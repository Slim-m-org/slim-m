// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a direct message, mention, group message or error chimes at all.
///
/// A pure local device preference with no server truth, the same shape
/// `voice_settings_controller.dart`'s `VoiceSettingsState` already documents
/// for join/leave and call-ring sounds - those stay there, beside the call
/// preferences they belong to, while this one lives in Personal >
/// Notifications beside the push registration status it is the in-app
/// counterpart of.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';

const messageSoundsEnabledKey = 'slimm.notifications.message_sounds_enabled';

class MessageSoundSettingsController extends StateNotifier<bool> {
  MessageSoundSettingsController(this._ref) : super(true) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    state = prefs.getBool(messageSoundsEnabledKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(messageSoundsEnabledKey, enabled);
  }
}

final messageSoundSettingsProvider =
    StateNotifierProvider<MessageSoundSettingsController, bool>(
      (ref) => MessageSoundSettingsController(ref),
    );
