// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this device plays the soundboard clips other people trigger in a
/// call: a local preference with no server truth, like the module sound switch.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../providers/providers.dart';

const soundboardSoundsEnabledKey = 'slimm.voice.soundboard_sounds';
const soundboardVolumeKey = 'slimm.voice.soundboard_volume';

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

/// How loud clips play on this device, 0 to 1, kept apart from the mute switch
/// so unmuting brings back the level that was set.
class SoundboardVolumeController extends Notifier<double> {
  var _disposed = false;

  @override
  double build() {
    ref.onDispose(() => _disposed = true);
    final loaded = ref.read(preferencesProvider).valueOrNull;
    if (loaded == null) _load();
    return _read(loaded);
  }

  double _read(SharedPreferences? prefs) =>
      (prefs?.getDouble(soundboardVolumeKey) ?? 1.0).clamp(0.0, 1.0);

  Future<void> _load() async {
    final prefs = await ref.read(preferencesProvider.future);
    if (_disposed) return;
    state = _read(prefs);
  }

  Future<void> setVolume(double volume) async {
    state = volume.clamp(0.0, 1.0);
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setDouble(soundboardVolumeKey, state);
  }
}

final soundboardVolumeProvider =
    NotifierProvider<SoundboardVolumeController, double>(
      SoundboardVolumeController.new,
    );
