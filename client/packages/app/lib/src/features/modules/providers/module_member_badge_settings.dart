// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which modules may draw their badge beside names in the member list.
///
/// A per-device choice, empty by default: a module's badge competes with the
/// role chip in a 236px row, so it is opt-in. The profile card is unaffected.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';

const moduleMemberBadgesKey = 'slimm.modules.member_list_badges';

class ModuleMemberBadgeSettings extends Notifier<Set<String>> {
  var _disposed = false;

  @override
  Set<String> build() {
    ref.onDispose(() => _disposed = true);
    _load();
    return const {};
  }

  Future<void> _load() async {
    final prefs = await ref.read(preferencesProvider.future);
    if (_disposed) return;
    state = {...?prefs.getStringList(moduleMemberBadgesKey)};
  }

  Future<void> setShown(String moduleId, bool shown) async {
    state = shown ? {...state, moduleId} : ({...state}..remove(moduleId));
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setStringList(moduleMemberBadgesKey, state.toList());
  }
}

final moduleMemberBadgeSettingsProvider =
    NotifierProvider<ModuleMemberBadgeSettings, Set<String>>(
      ModuleMemberBadgeSettings.new,
    );
