// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether module badges draw beside names in the member list.
///
/// A per-user, per-device choice, off by default: a module's badge competes
/// with the role chip in a 236px row. Members cannot list installed modules,
/// so one switch covers them all. The profile card is unaffected.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';

const moduleMemberBadgesKey = 'slimm.modules.member_list_badges_enabled';

class ModuleMemberBadgeSettings extends Notifier<bool> {
  var _disposed = false;

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await ref.read(preferencesProvider.future);
    if (_disposed) return;
    state = prefs.getBool(moduleMemberBadgesKey) ?? false;
  }

  Future<void> setShown(bool shown) async {
    state = shown;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(moduleMemberBadgesKey, shown);
  }
}

final moduleMemberBadgeSettingsProvider =
    NotifierProvider<ModuleMemberBadgeSettings, bool>(
      ModuleMemberBadgeSettings.new,
    );
