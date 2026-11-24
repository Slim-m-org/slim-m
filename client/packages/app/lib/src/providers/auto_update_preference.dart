// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this install may update itself on launch.
///
/// On unless the person turned it off (decision 0025, addendum 2026-09-29):
/// nothing asks at signup or at the splash, and Settings under About is the
/// one place the choice is made. An absent key means the default, and a saved
/// answer of either kind is always kept.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:shared_preferences/shared_preferences.dart';

import 'providers.dart';

const autoUpdateKey = 'slimm.updates.automatic';

/// The stored answer, or on when nothing was ever saved. Read directly (not
/// through the provider) by the splash, which runs before the widget tree
/// exists.
bool loadAutoUpdatePreference(SharedPreferences prefs) =>
    prefs.getBool(autoUpdateKey) ?? true;

class AutoUpdateController extends StateNotifier<bool> {
  AutoUpdateController(this._ref) : super(true) {
    _load();
  }

  final Ref _ref;
  var _answered = false;

  /// The stored answer, unless one was given while this was still reading:
  /// an answer made here and now is the newer truth, and letting the load
  /// land on top of it would silently undo the switch the user just moved.
  Future<void> _load() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      if (!_answered && mounted) state = loadAutoUpdatePreference(prefs);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read the auto-update preference; keeping it on',
        error,
        stack,
      );
    }
  }

  Future<void> set(bool enabled) async {
    _answered = true;
    state = enabled;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(autoUpdateKey, enabled);
  }
}

final autoUpdateProvider = StateNotifierProvider<AutoUpdateController, bool>(
  AutoUpdateController.new,
);
