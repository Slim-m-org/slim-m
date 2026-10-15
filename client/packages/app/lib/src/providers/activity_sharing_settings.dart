// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which sources tell others what this device is doing.
///
/// Every switch is off until the person turns it on (decision 0044), and
/// there is one per source so turning on music never turns on game
/// detection. A device-local preference: the server never learns the
/// setting, only the activity that an enabled source produces.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const shareListeningKey = 'slimm.presence.share_listening';
const shareGameKey = 'slimm.presence.share_game';

class ActivitySwitchController extends StateNotifier<bool> {
  ActivitySwitchController(this._ref, this._key) : super(false) {
    _load();
  }

  final Ref _ref;
  final String _key;

  /// A choice made before the stored value loaded is newer than it.
  bool _chosen = false;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    if (mounted && !_chosen) state = prefs.getBool(_key) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    _chosen = true;
    state = enabled;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_key, enabled);
  }
}

/// The switch stored under a preference key.
final activitySwitchProvider =
    StateNotifierProvider.family<ActivitySwitchController, bool, String>(
      (ref, key) => ActivitySwitchController(ref, key),
    );

final shareListeningProvider = activitySwitchProvider(shareListeningKey);

final shareGameProvider = activitySwitchProvider(shareGameKey);
