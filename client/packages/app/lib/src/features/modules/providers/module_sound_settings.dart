// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a module's `notes` scene op (`module_scene.dart`) is allowed to
/// make sound at all.
///
/// A pure local device preference with no server truth, the identical shape
/// `messageSoundSettingsProvider` already gives message chimes - copied
/// rather than shared because the two answer different questions ("does a
/// message chime" against "does a module's own sound effect play") and a
/// person may want one without the other, the same reasoning that already
/// keeps voice join/leave sounds on their own switch.
///
/// This is the "turn it off" half of the defence against a module's sound
/// being an abuse vector; see `module_scene.dart`'s `NotesOp` doc comment for
/// the other half (never autoplayed).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';

const moduleSoundEnabledKey = 'slimm.modules.sound_enabled';

class ModuleSoundSettingsController extends StateNotifier<bool> {
  ModuleSoundSettingsController(this._ref) : super(true) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    state = prefs.getBool(moduleSoundEnabledKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(moduleSoundEnabledKey, enabled);
  }
}

final moduleSoundSettingsProvider =
    StateNotifierProvider<ModuleSoundSettingsController, bool>(
      (ref) => ModuleSoundSettingsController(ref),
    );
