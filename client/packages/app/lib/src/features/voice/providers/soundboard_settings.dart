// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this device plays the soundboard clips other people trigger in a
/// call: a local preference with no server truth, like the module sound switch.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';

const soundboardSoundsEnabledKey = 'slimm.voice.soundboard_sounds';

class SoundboardSoundsController extends Notifier<bool> {
  var _disposed = false;

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    final loaded = ref.read(preferencesProvider).valueOrNull;
    if (loaded == null) _load();
    return loaded?.getBool(soundboardSoundsEnabledKey) ?? true;
  }

  Future<void> _load() async {
    final prefs = await ref.read(preferencesProvider.future);
    if (_disposed) return;
    state = prefs.getBool(soundboardSoundsEnabledKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(soundboardSoundsEnabledKey, enabled);
  }
}

final soundboardSoundsProvider =
    NotifierProvider<SoundboardSoundsController, bool>(
      SoundboardSoundsController.new,
    );
